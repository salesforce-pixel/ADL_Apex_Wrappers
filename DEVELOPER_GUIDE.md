# Developer Guide: `ADLClient` and `ADLS3Uploader`

A practical guide to using the `ADLClient` and `ADLS3Uploader` Apex classes to provision and manage Agentforce Data Libraries from your own code — Queueables, scheduled jobs, Flow Invocables, REST resources, custom LWCs, or anywhere else you need to manage SFDRIVE grounding libraries programmatically.

> **API maturity:** Salesforce REST API v66.0 (Beta). Response shapes may change between versions. One known shift — the `/status` endpoint switched from a `stages` map (v66) to a `stageDetails` array (v67+) — is already handled inside the wrapper. Your Apex code reads a single normalized `stageDetails` list regardless of which API version responded.

---

## Table of Contents

1. [What These Classes Do](#what-these-classes-do)
2. [Prerequisites](#prerequisites)
3. [The End-to-End Flow](#the-end-to-end-flow)
4. [Choosing the Right Method — Decision Guide](#choosing-the-right-method--decision-guide)
5. [`ADLClient` Method Reference](#adlclient-method-reference)
6. [`ADLS3Uploader` Method Reference](#adls3uploader-method-reference)
7. [Exception Model](#exception-model)
8. [Worked Examples](#worked-examples)
9. [Common Pitfalls](#common-pitfalls)
10. [Limits and Considerations](#limits-and-considerations)
11. [What This Wrapper Does Not Do](#what-this-wrapper-does-not-do)
12. [Endpoint Map](#endpoint-map)

---

## What These Classes Do

The Agentforce Data Library (ADL) REST API is a multi-step pipeline: create a library → check readiness → request presigned S3 URLs → upload bytes to S3 → trigger indexing → poll status. Two HTTP domains are involved (Salesforce + AWS S3), each with its own auth model and failure modes.

These wrappers split that work into two focused classes:

| Class | Responsibility | Talks to |
|---|---|---|
| `ADLClient` | All Salesforce ADL REST calls — CRUD on libraries, readiness, URL minting, indexing, status | `*.salesforce.com` (Named Credential `ADL_NC`) |
| `ADLS3Uploader` | Uploading file bytes to S3 using the presigned URLs returned by `ADLClient` | `*.s3.amazonaws.com` (Remote Site Setting) |

This is **Layer 1** — HTTP, JSON, validation, and error mapping. Orchestration (ordering steps, polling, chunking large batches) belongs in a layer you write on top, because different consumers have different orchestration needs.

### Why two classes, not one

`ADLClient` and `ADLS3Uploader` are intentionally separate. They target different services, use different authentication models, and fail in different ways. Folding them into one class would either route S3 callouts through the Named Credential (which breaks the AWS signature) or smear two different error vocabularies into one exception type.

### Execution context

Three distinct concerns are at play. Keep them separate:

| Concern | Tied to | Governs |
|---|---|---|
| Apex transaction (SOQL, DML, sharing) | The **invoking user** — whoever triggered the LWC, Quick Action, scheduled job, etc. | Standard Apex permissions, FLS, sharing, `UserInfo.getUserId()` |
| Permission to use the External Credential | The **invoking user** + `ADL_Access` permission set | Whether the platform will mint a token for this user's callout |
| Identity inside the ADL REST API | The **Run As user** from the External Client App | OAuth token identity; server-side permissions inside the ADL service |

So if your code does `SELECT VersionData FROM ContentVersion WHERE ...` followed by `ADLS3Uploader.upload(...)`:

- The SOQL is governed by the **invoking user's** record access.
- The platform checks the **invoking user** has `ADL_Access` before minting a token.
- The minted token represents the **Run As user**, which is the identity the ADL service sees.

**Async contexts work fine.** The wrapper uses `callout:ADL_NC`, so authentication doesn't depend on the invoking user's session token — only on their permission set assignment. It works from `@future`, `Queueable`, `Batch`, and `Scheduled` Apex as well as synchronous contexts. (Note: for `Scheduled` Apex, the "invoking user" is the user who scheduled the job — make sure *they* have the permission set.)

> *The `ADLClient` class-level comment historically mentioned `UserInfo.getSessionId()` and synchronous-only contexts — that note is stale and refers to an earlier implementation. The actual `doCallout` method uses `callout:ADL_NC`, which works in async contexts too.*

---

## Prerequisites

Before using these classes from your own code, your org must already have the full ADL stack wired up: External Client App, External Credential, Named Credential (`ADL_NC`), `ADL_Access` permission set, and an S3 Remote Site Setting.

If you haven't completed this setup, follow the **Required Org Setup** section of [`README.md`](./README.md) (steps 1–8). The wrapper classes will not function without all five pieces.

Once setup is done, verify with this in **Developer Console → Execute Anonymous**:

```apex
ADLClient.LibraryListOutput out = ADLClient.listLibraries(null);
System.debug('Libraries: ' + out.totalSize);
```

A successful call confirms auth is working end-to-end. Fix that before moving on.

---

## The End-to-End Flow

Here is the canonical sequence for provisioning a new library with files. Every method below maps to one endpoint.

```
1. createLibrary()            → get libraryId
2. checkUploadReadiness()     → wait until ready=true
3. requestUploadUrls()        → get presigned S3 URLs
4. ADLS3Uploader.uploadAll()  → PUT bytes to S3
5. triggerIndexing()          → kick off indexing on uploaded files
6. getStatus() (poll)         → wait for terminal state (READY/FAILED/...)
```

For an already-provisioned library, the day-2 flow is steps 2 → 3 → 4 → `addFiles()` → 6.

### A typical lifecycle, end to end

Here's the same flow narrated as a story, with rationale for each call:

1. **User clicks "Create knowledge base" on a custom object.** A Quick Action invokes `createLibrary(...)` synchronously and stores the returned `libraryId` on the parent record. Fast — single callout, returns immediately.

2. **Same transaction continues, or a follow-up Queueable kicks off.** Call `checkUploadReadiness(libraryId, 120000)` with the long-poll. The first time, this usually takes 5–20 seconds while Salesforce provisions backing infra.

3. **User attaches files in the UI.** When they hit "Index", a Queueable starts. It calls `requestUploadUrls(libraryId, fileNames)` to mint presigned S3 URLs. **Do this in the same Queueable that does the upload** — the URLs expire in 15 minutes.

4. **The Queueable calls `ADLS3Uploader.uploadAll(urls, blobs)`.** Each upload is a callout, so respect the 100-callout-per-transaction limit. For more than ~80 files, chunk across multiple Queueable executions.

5. **Same Queueable finishes by calling `triggerIndexing(libraryId, uploadedFiles)`** (first time) or `addFiles(libraryId, uploadedFiles)` (subsequent times). The library status transitions to `IN_PROGRESS`.

6. **A Scheduled job runs every few minutes**, calling `getStatus(libraryId)` for each `IN_PROGRESS` library and checking `ADLClient.isTerminal(status)`. When terminal, it updates the parent record's status field and unschedules itself.

---

## Choosing the Right Method — Decision Guide

The method reference below tells you *how* to call each one. This section tells you *which* to call and *when*.

### "I want to..."

| Goal | Method to call | Notes |
|---|---|---|
| Show a list of libraries in a UI | `listLibraries(null)` | Pass `'SFDRIVE'` / `'KNOWLEDGE'` / `'RETRIEVER'` to filter |
| Create a new library for the first time | `createLibrary(...)` | Returns `libraryId` — persist this against your parent record |
| Read a library's current metadata | `getLibrary(libraryId)` | Cheap; safe to call from LWC controllers |
| Rename a library or update its description | `updateLibrary(libraryId, ...)` | PATCH — only send fields that change |
| Remove a library record | `deleteLibrary(libraryId)` | Returns `true` on 204; underlying DLO/DMO/Search Index/Retriever are not removed |
| Find out if a freshly-created library can accept uploads yet | `checkUploadReadiness(libraryId, 120000)` | Long-poll up to 2 min; the API does the waiting for you |
| Get URLs to upload file bytes | `requestUploadUrls(libraryId, fileNames)` | URLs expire in ~15 min — use them immediately |
| Actually upload the bytes to S3 | `ADLS3Uploader.upload(...)` or `uploadAll(...)` | Direct PUT to S3, not Salesforce |
| **First-time** indexing on a brand new library | `triggerIndexing(libraryId, files)` | Use this **once**, right after the initial S3 uploads |
| Add **more** files to a library that's already been indexed | `addFiles(libraryId, files)` | Use this for every subsequent add, day 2 onwards |
| Check whether indexing has finished | `getStatus(libraryId)` + `isTerminal(status)` | Poll on an interval; `isTerminal()` tells you when to stop |

### `triggerIndexing` vs `addFiles` — the most common confusion

These methods take the same DTO (`List<UploadedFileInfo>`) but hit different endpoints. The rule is simple:

- **`triggerIndexing`** = the *first* time you populate a library. It transitions the library from `NO_SOURCES` to `IN_PROGRESS` and provisions the underlying vector index. Calling it on a library that's already been indexed is wrong.
- **`addFiles`** = every time after that. It appends new files to an existing index.

If you don't know which state the library is in, inspect the library's `groundingFileRefs` first. The pattern used in `ADLConsoleController` is:

```apex
ADLClient.LibraryOutput lib = ADLClient.getLibrary(libraryId);
Boolean hasFiles = lib.groundingSource != null
    && lib.groundingSource.groundingFileRefs != null
    && !lib.groundingSource.groundingFileRefs.isEmpty();

if (hasFiles) {
    ADLClient.addFiles(libraryId, uploaded);
} else {
    ADLClient.triggerIndexing(libraryId, uploaded);
}
```

### When to call what in async vs sync contexts

| Context | Recommended methods | Why |
|---|---|---|
| LWC `@AuraEnabled` controller | `listLibraries`, `getLibrary`, `getStatus`, `checkUploadReadiness` (short wait) | Read-only, fast, safe to block on |
| Button click / Quick Action | `createLibrary`, `updateLibrary`, `deleteLibrary` | Single callout, returns quickly |
| Queueable / Batch | `requestUploadUrls` → `ADLS3Uploader.uploadAll` → `triggerIndexing` / `addFiles` | Multi-step, multiple callouts, may exceed sync request budgets |
| Scheduled Apex | `getStatus` polling | Periodic status checks for libraries still indexing |
| Anywhere | All of the above — auth is via Named Credential, so context doesn't restrict it | |

---

## `ADLClient` Method Reference

All methods are `public static`. All throw `ADLClient.ADLException` or one of its subclasses on failure.

### `listLibraries(String sourceType)`

Discovery. Pass `null` for all libraries, or one of `'SFDRIVE'`, `'KNOWLEDGE'`, `'RETRIEVER'` to filter.

```apex
ADLClient.LibraryListOutput out = ADLClient.listLibraries(null);
System.debug(out.totalSize + ' libraries found');
for (ADLClient.LibraryOutput lib : out.libraries) {
    System.debug(lib.developerName + ' → ' + lib.libraryId);
}
```

**Returns:** `LibraryListOutput` with `libraries` and `totalSize` fields. The summary objects do **not** include `groundingFileRefs` — call `getLibrary(id)` to hydrate the file list.

### `getLibrary(String libraryId)`

Fetches a single library by ID, including its `groundingSource.groundingFileRefs` (the file list).

```apex
ADLClient.LibraryOutput lib = ADLClient.getLibrary('0XXxx0000000001AAA');
System.debug('Name: ' + lib.masterLabel);
if (lib.groundingSource != null && lib.groundingSource.groundingFileRefs != null) {
    for (ADLClient.GroundingFileRef f : lib.groundingSource.groundingFileRefs) {
        System.debug(f.fileName + ' — ' + f.fileSize + ' bytes');
    }
}
```

### `createLibrary(CreateLibraryInput input)`

Creates the library shell. The wrapper validates `developerName` against `^[a-zA-Z][a-zA-Z0-9_]*$` client-side so you fail fast before the HTTP call.

```apex
ADLClient.CreateLibraryInput in = new ADLClient.CreateLibraryInput();
in.masterLabel   = 'Product Manuals Library';
in.developerName = 'Product_Manuals_Library';
in.description   = 'Product manual PDFs ingested for service agent grounding';

ADLClient.GroundingSourceInput src = new ADLClient.GroundingSourceInput();
src.sourceType = 'SFDRIVE';
in.groundingSource = src;

ADLClient.LibraryOutput lib = ADLClient.createLibrary(in);
String libraryId = lib.libraryId;  // keep this for every subsequent call
```

**Validation rules** (raised as `ADLClientException` before the HTTP call):

- `masterLabel` required, max 80 chars
- `developerName` required, max 80 chars, must match `^[a-zA-Z][a-zA-Z0-9_]*$`
- `description` optional, max 255 chars

### `updateLibrary(String libraryId, UpdateLibraryInput input)`

PATCH. Only send fields that change.

```apex
ADLClient.UpdateLibraryInput patch = new ADLClient.UpdateLibraryInput();
patch.description = 'Updated description';
ADLClient.LibraryOutput updated = ADLClient.updateLibrary(libraryId, patch);
```

Same length limits apply: `masterLabel` ≤ 80, `description` ≤ 255.

### `deleteLibrary(String libraryId)`

Deletes the ADL record. Returns `true` on HTTP 204. The underlying Data Lake Object, Data Model Object, Search Index, and Retriever are **not** removed by this call — clean those up separately if you need to fully decommission the infrastructure.

```apex
Boolean ok = ADLClient.deleteLibrary(libraryId);
if (!ok) {
    // 204 wasn't returned — caller decides whether to retry
}
```

### `checkUploadReadiness(String libraryId, Integer waitMaxTimeMs)`

A newly-created library isn't immediately ready to receive uploads — backing infrastructure is being provisioned. This endpoint either returns immediately or long-polls server-side up to `waitMaxTimeMs` (0–120000).

```apex
// Long-poll up to 2 minutes
ADLClient.UploadReadinessOutput r = ADLClient.checkUploadReadiness(libraryId, 120000);
if (!r.ready) {
    throw new MyAppException('Library not ready: ' + r.message);
}
```

### `requestUploadUrls(String libraryId, List<String> fileNames)`

Mints presigned S3 PUT URLs — one per file. Each URL is valid for ~15 minutes. The returned `headers` map is part of the signature and must be passed through to `ADLS3Uploader` unchanged.

```apex
List<String> names = new List<String>{ 'installation_guide.pdf', 'warranty_policy.pdf' };
ADLClient.UploadUrlsOutput urls = ADLClient.requestUploadUrls(libraryId, names);
// urls.uploadUrls[i].uploadUrl  — pass to ADLS3Uploader unchanged
// urls.uploadUrls[i].filePath   — pass to triggerIndexing later
// urls.uploadUrls[i].headers    — pass to ADLS3Uploader EXACTLY as-is
```

> **Mint URLs in the same transaction (or Queueable execution) as the upload.** Presigned URLs expire after about 15 minutes. If you need to defer, call `requestUploadUrls` again just before uploading.

### `triggerIndexing(libraryId, List<UploadedFileInfo>)`

**First-time** provisioning of a library. Use this once per library — the first time files are indexed. Transitions the library from `NO_SOURCES` to `IN_PROGRESS` and provisions the underlying vector index.

```apex
List<ADLClient.UploadedFileInfo> indexed = new List<ADLClient.UploadedFileInfo>();
for (ADLS3Uploader.UploadResult ur : uploadResults) {
    indexed.add(new ADLClient.UploadedFileInfo(ur.filePath, ur.fileSize));
}
ADLClient.ProvisionOutput prov = ADLClient.triggerIndexing(libraryId, indexed);
```

The `filePath` and `fileSize` values come from `ADLS3Uploader.UploadResult` after a successful S3 upload.

### `addFiles(libraryId, List<UploadedFileInfo>)`

Day-2 file additions. Returns the new `groundingFileRefs` for audit.

```apex
ADLClient.AddFilesOutput out = ADLClient.addFiles(libraryId, indexed);
System.debug('Files accepted: ' + out.filesAccepted);
```

### `getStatus(String libraryId)`

Returns indexing progress. Use `ADLClient.isTerminal(status)` to decide when to stop polling.

```apex
ADLClient.StatusOutput s = ADLClient.getStatus(libraryId);
String overall = s.indexingStatus.status;        // READY / IN_PROGRESS / FAILED / ...
String stage   = s.indexingStatus.currentStage;
if (ADLClient.isTerminal(overall)) {
    // READY, FAILED, INCOMPLETE, or NO_SOURCES — stop polling
}
for (ADLClient.StageDetail d : s.indexingStatus.stageDetails) {
    System.debug(d.stage + ': ' + d.status);
}
```

> **API version note:** the wrapper normalizes the v66 (`stages` map) and v67+ (`stageDetails` array) response shapes into a single populated `stageDetails` list, so your code works across API versions.

### `isTerminal(String status)`

Convenience helper for polling loops. Returns `true` when the overall status is `READY`, `FAILED`, `INCOMPLETE`, or `NO_SOURCES` — i.e. polling should stop.

```apex
String status = ADLClient.getStatus(libraryId).indexingStatus.status;
if (ADLClient.isTerminal(status)) {
    // Stop polling
}
```

---

## `ADLS3Uploader` Method Reference

All methods are `public static`. Callouts go directly to S3 (no Named Credential).

### `upload(ADLClient.UploadUrl url, Blob body)` *(convenience overload)*

The typical call site. Pass through one entry from `requestUploadUrls` plus the file's bytes.

```apex
ContentVersion cv = [SELECT Title, VersionData FROM ContentVersion WHERE Id = :cvId];
ADLS3Uploader.UploadResult r = ADLS3Uploader.upload(urls.uploadUrls[0], cv.VersionData);
System.debug('S3 ETag: ' + r.eTag);
```

### `upload(String uploadUrl, Map<String, String> headers, String filePath, String fileName, Blob body)` *(low-level form)*

Use this if you've stored URL components separately and want to pass them in directly. The `headers` map must be exactly what `ADLClient.UploadUrl.headers` returned; adding or removing any header breaks the AWS Sig V4 signature.

```apex
ADLS3Uploader.UploadResult r = ADLS3Uploader.upload(
    url.uploadUrl,
    url.headers,
    url.filePath,
    url.fileName,
    bytes
);
```

### `uploadAll(List<UploadUrl> urls, Map<String, Blob> blobsByFileName)`

Sequential batch upload, keyed by `fileName`. Apex doesn't allow parallel callouts.

The method **fails fast** if the batch would exceed your remaining transaction callout budget — chunk via `Queueable` for large sets.

```apex
Map<String, Blob> blobs = new Map<String, Blob>();
for (ContentVersion cv : [SELECT Title, VersionData FROM ContentVersion WHERE Id IN :ids]) {
    blobs.put(cv.Title, cv.VersionData);  // key must match fileName passed earlier
}
List<ADLS3Uploader.UploadResult> results = ADLS3Uploader.uploadAll(urls.uploadUrls, blobs);

// Convert results to UploadedFileInfo for the next ADLClient call
List<ADLClient.UploadedFileInfo> uploaded = new List<ADLClient.UploadedFileInfo>();
for (ADLS3Uploader.UploadResult r : results) {
    uploaded.add(new ADLClient.UploadedFileInfo(r.filePath, r.fileSize));
}
```

**Constraints:**

- File names must be unique within a batch (the map cannot disambiguate duplicates). If duplicate names are valid for your use case, call `upload(...)` per file and key your own data structure by `filePath`.
- On mid-batch failure, prior successful S3 uploads are **not** rolled back — S3 doesn't support that.
- A presigned URL expires ~15 minutes after issuance; if you delay, mint fresh ones.

### Critical S3 rules (why this class exists)

These are easy to get wrong if you call S3 directly:

1. **Never route through a Named Credential.** It would add an `Authorization` header and break the AWS Sig V4 signature embedded in the URL query string. Use a Remote Site Setting instead.
2. **Send the `headers` map exactly as returned.** No extras. The signature covers `X-Amz-SignedHeaders` — additions cause `403 SignatureDoesNotMatch`.
3. **Use `setBodyAsBlob`, not `setBody`.** A string body produces `400 Bad Request`.
4. **Do not URL-decode the presigned URL.** Pass it through unchanged.

The wrapper encodes all four rules; you only break them by going around it.

---

## Exception Model

Both classes define a small hierarchy. Catch the parent when you want a single handler, or a subclass when you need to distinguish.

```
ADLException (abstract)
├── ADLClientException   — validation failed; no HTTP call was made
└── ADLApiException      — Salesforce returned non-2xx (statusCode, errorCode, responseBody)

S3Exception (abstract)
├── S3ClientException    — validation failed; no HTTP call was made
└── S3UploadException    — S3 returned non-2xx (statusCode, awsErrorCode, responseBody, fileName)
```

`S3UploadException` includes a built-in remediation hint in the message for common cases:

| Status | AWS Code | Likely cause |
|---|---|---|
| 403 | `SignatureDoesNotMatch` | Headers tampered with, Authorization header injected, or URL decoded |
| 403 | `AccessDenied` | Presigned URL expired — re-mint via `requestUploadUrls` |
| 400 | — | Body sent as string instead of Blob |

### Recommended catch patterns

**Broad — "anything from these wrappers":**

```apex
try {
    // ADLClient + ADLS3Uploader calls
} catch (ADLClient.ADLException e) {
    System.debug('ADL error: ' + e.getMessage());
} catch (ADLS3Uploader.S3Exception e) {
    System.debug('S3 error: ' + e.getMessage() + ' (file: ' + e.fileName + ')');
}
```

**Narrow — distinguish "your inputs were bad" from "the server rejected them":**

```apex
try {
    ADLClient.createLibrary(input);
} catch (ADLClient.ADLClientException e) {
    // Show the user a form-validation error
    return Response.badRequest(e.getMessage());
} catch (ADLClient.ADLApiException e) {
    // Log full context for triage
    System.debug('API ' + e.statusCode + ' [' + e.errorCode + ']: ' + e.responseBody);
    return Response.error(e.getMessage());
}
```

`ADLApiException` carries `statusCode`, `errorCode` (parsed Salesforce-style), and `responseBody` for diagnostics. `S3UploadException` additionally carries `awsErrorCode` (e.g. `SignatureDoesNotMatch`, `AccessDenied`) parsed from the S3 XML error body.

---

## Worked Examples

### Example 1: Full provisioning (synchronous)

A single method that creates a library, uploads two files, and triggers indexing. Polling is left as a separate method (since indexing can take minutes).

```apex
public class ProductManualsLibraryBootstrap {

    public static String provision(List<ContentVersion> versions) {
        // 1. Create
        ADLClient.CreateLibraryInput cIn = new ADLClient.CreateLibraryInput();
        cIn.masterLabel   = 'Product Manuals Library';
        cIn.developerName = 'Product_Manuals_Library';
        ADLClient.GroundingSourceInput src = new ADLClient.GroundingSourceInput();
        src.sourceType = 'SFDRIVE';
        cIn.groundingSource = src;

        String libraryId = ADLClient.createLibrary(cIn).libraryId;

        // 2. Wait for readiness
        ADLClient.UploadReadinessOutput rdy = ADLClient.checkUploadReadiness(libraryId, 120000);
        if (!rdy.ready) {
            throw new CalloutException('Library not ready: ' + rdy.message);
        }

        // 3. Mint upload URLs
        List<String> names = new List<String>();
        Map<String, Blob> blobs = new Map<String, Blob>();
        for (ContentVersion cv : versions) {
            names.add(cv.Title);
            blobs.put(cv.Title, cv.VersionData);
        }
        ADLClient.UploadUrlsOutput urls = ADLClient.requestUploadUrls(libraryId, names);

        // 4. Upload to S3
        List<ADLS3Uploader.UploadResult> uploaded = ADLS3Uploader.uploadAll(urls.uploadUrls, blobs);

        // 5. Trigger indexing
        List<ADLClient.UploadedFileInfo> info = new List<ADLClient.UploadedFileInfo>();
        for (ADLS3Uploader.UploadResult r : uploaded) {
            info.add(new ADLClient.UploadedFileInfo(r.filePath, r.fileSize));
        }
        ADLClient.triggerIndexing(libraryId, info);

        return libraryId;
    }

    // Poll separately — call from a scheduled job or LWC.
    public static Boolean isReady(String libraryId) {
        ADLClient.StatusOutput s = ADLClient.getStatus(libraryId);
        return s.indexingStatus != null && ADLClient.isTerminal(s.indexingStatus.status);
    }
}
```

### Example 2: Day-2 file additions

```apex
public static void addFilesToLibrary(String libraryId, Map<String, Blob> filesByName) {
    // 1. Confirm readiness
    ADLClient.UploadReadinessOutput readiness =
        ADLClient.checkUploadReadiness(libraryId, 0);
    if (!readiness.ready) throw new CalloutException(readiness.message);

    // 2. Mint URLs and upload
    List<ADLClient.UploadUrl> urls =
        ADLClient.requestUploadUrls(libraryId, new List<String>(filesByName.keySet())).uploadUrls;
    List<ADLS3Uploader.UploadResult> results = ADLS3Uploader.uploadAll(urls, filesByName);

    // 3. Append — addFiles, NOT triggerIndexing
    List<ADLClient.UploadedFileInfo> uploaded = new List<ADLClient.UploadedFileInfo>();
    for (ADLS3Uploader.UploadResult r : results) {
        uploaded.add(new ADLClient.UploadedFileInfo(r.filePath, r.fileSize));
    }
    ADLClient.addFiles(libraryId, uploaded);
}
```

### Example 3: Queueable wrapper for large file batches

Every S3 PUT counts against the per-transaction callout limit (100), so large batches should be chunked across Queueable executions.

```apex
public class ADLUploadQueueable implements Queueable, Database.AllowsCallouts {
    private String libraryId;
    private Map<String, Blob> remaining;

    public ADLUploadQueueable(String libraryId, Map<String, Blob> files) {
        this.libraryId = libraryId;
        this.remaining = files;
    }

    public void execute(QueueableContext context) {
        // Chunk to stay well under the 100-callout limit
        // (need budget for: 1 readiness + 1 requestUrls + N S3 PUTs + 1 addFiles)
        Integer chunkSize = 50;

        Map<String, Blob> thisBatch = new Map<String, Blob>();
        Map<String, Blob> nextBatch = new Map<String, Blob>();

        Integer i = 0;
        for (String name : remaining.keySet()) {
            if (i < chunkSize) {
                thisBatch.put(name, remaining.get(name));
            } else {
                nextBatch.put(name, remaining.get(name));
            }
            i++;
        }

        // Run one chunk (fresh URLs in the same execution → no expiry risk)
        List<ADLClient.UploadUrl> urls =
            ADLClient.requestUploadUrls(libraryId, new List<String>(thisBatch.keySet())).uploadUrls;
        List<ADLS3Uploader.UploadResult> results = ADLS3Uploader.uploadAll(urls, thisBatch);

        List<ADLClient.UploadedFileInfo> uploaded = new List<ADLClient.UploadedFileInfo>();
        for (ADLS3Uploader.UploadResult r : results) {
            uploaded.add(new ADLClient.UploadedFileInfo(r.filePath, r.fileSize));
        }
        ADLClient.addFiles(libraryId, uploaded);

        // Chain the next chunk if any remain
        if (!nextBatch.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new ADLUploadQueueable(libraryId, nextBatch));
        }
    }
}
```

### Example 4: Polling with Queueable chaining

Apex has no `Thread.sleep`, so real polling needs Queueable chaining or Scheduled Apex. Sketch:

```apex
public class ADLStatusPoller implements Queueable, Database.AllowsCallouts {
    private String libraryId;
    private Integer attempt;
    private Integer maxAttempts;

    public ADLStatusPoller(String libraryId, Integer maxAttempts) {
        this(libraryId, 0, maxAttempts);
    }

    private ADLStatusPoller(String libraryId, Integer attempt, Integer maxAttempts) {
        this.libraryId = libraryId;
        this.attempt = attempt;
        this.maxAttempts = maxAttempts;
    }

    public void execute(QueueableContext context) {
        ADLClient.StatusOutput out = ADLClient.getStatus(libraryId);
        String status = out.indexingStatus == null ? 'NO_STATUS' : out.indexingStatus.status;

        if (ADLClient.isTerminal(status)) {
            // Update parent record, fire Platform Event, etc.
            return;
        }

        if (attempt + 1 >= maxAttempts) {
            // Give up — log or alert
            return;
        }

        if (!Test.isRunningTest()) {
            System.enqueueJob(new ADLStatusPoller(libraryId, attempt + 1, maxAttempts));
        }
    }
}
```

For production polling at a fixed cadence (e.g. every 2 minutes), prefer a Scheduled job that reads all `IN_PROGRESS` libraries from a custom object and polls each.

---

## Common Pitfalls

### 1. Adding an `Authorization` header to S3 callouts

The presigned URL carries its own AWS Sig V4 signature in the query string. Adding `Authorization: Bearer ...` (or letting a Named Credential do it) breaks the signature and you get HTTP 403 `SignatureDoesNotMatch`. Always go direct to S3 via Remote Site Setting — never through a Named Credential.

### 2. Using `setBody` instead of `setBodyAsBlob` for S3 uploads

`setBody(String)` reinterprets bytes through string encoding and corrupts binary files. `ADLS3Uploader.upload` already uses `setBodyAsBlob` — if you write your own S3 caller, do the same.

### 3. URL-decoding the presigned URL

The presigned URL contains URL-encoded query parameters that are part of the signature. Decoding them invalidates the signature. Pass the URL through unchanged.

### 4. Modifying the headers map

Every header in `ADLClient.UploadUrl.headers` is part of the signed header list (`X-Amz-SignedHeaders` in the URL). Adding, removing, or changing values causes `SignatureDoesNotMatch`. Pass the map through unchanged.

### 5. Confusing `triggerIndexing` with `addFiles`

- `triggerIndexing` → first-time provisioning. Use **once** per library, when transitioning from `NO_SOURCES`.
- `addFiles` → day-2 additions. Use for every subsequent upload.

The two endpoints accept identical DTOs, which makes the wrong choice an easy mistake. Use the `groundingFileRefs`-empty check shown above to pick the right one automatically.

### 6. Deferring uploads past presigned URL expiry

Presigned URLs are valid for ~15 minutes. If you mint them and then defer the upload (waiting for a callback, a user click, a different Queueable), the URLs may expire. Re-mint just before uploading rather than caching the URLs.

### 7. Ignoring the callout limit on batch uploads

Each S3 PUT counts against the per-transaction callout budget (100). A batch of 90 files plus the readiness check, URL request, and indexing call will exceed it. `ADLS3Uploader.uploadAll` checks this up front and throws, but you still need to chunk via Queueable for large batches.

### 8. Forgetting the `ADL_Access` permission set assignment

Every user who invokes the wrapper — LWC users, integration users running scheduled jobs, admins running `Execute Anonymous` — needs the `ADL_Access` permission set. Without it, token minting fails before the HTTP call leaves the org. This is unrelated to the Run As user on the External Client App. See `README.md` Step 5.

---

## Limits and Considerations

| Constraint | Value | Notes |
|------------|-------|-------|
| Files per library | 1,000 | Enforced server-side; UI also enforces |
| Presigned URL TTL | ~15 minutes | Re-mint if deferring uploads |
| `waitMaxTimeMs` on readiness | 0–120,000 ms | Validated client-side |
| Apex callouts per transaction | 100 | Includes both ADL and S3 calls |
| Default callout timeout | 120,000 ms | Configurable per-request via `HttpRequest.setTimeout` if you bypass the wrappers |
| Master label length | 80 chars | Validated client-side |
| Developer name pattern | `^[a-zA-Z][a-zA-Z0-9_]*$` | Validated client-side |
| Description length | 255 chars | Validated client-side |
| API version | v66.0 Beta | `/status` shape normalised between v66 and v67+ |

### Sharing model

- `ADLClient` is declared `with sharing` — it performs no DML or SOQL, so the keyword has no effect, but it signals intent.
- `ADLS3Uploader` is declared `without sharing` for the same reason — also performs no DML or SOQL. The explicit declaration silences static-analysis warnings.

Neither class enforces object- or field-level security on its own. If you expose them through public-facing entry points, perform your own access checks before calling.

---

## What This Wrapper Does Not Do

Keep these in your orchestration layer:

- **Polling.** `getStatus` is a single call; you build the wait loop. See Example 4 for a Queueable pattern.
- **Chunking.** Large file batches must be split across transactions (Apex callout limit = 100 per transaction; `uploadAll` will fail fast if you'd exceed it).
- **Retries.** No automatic retry on transient failures. Wrap calls in your own retry policy if needed.
- **DML.** Nothing is written to Salesforce objects. If you want to persist `libraryId` against a parent record, do it in the caller.
- **One-shot "upload and index" convenience.** Deliberately omitted — the S3 upload step is a callout to a different host and needs to be handled separately for callout limits, retry logic, and error attribution. Build a Layer 2 orchestrator on top if you want that.

---

## Endpoint Map

| Apex method | HTTP | Path |
|---|---|---|
| `listLibraries` | GET | `/einstein/data-libraries[?sourceType=...]` |
| `createLibrary` | POST | `/einstein/data-libraries` |
| `getLibrary` | GET | `/einstein/data-libraries/{id}` |
| `updateLibrary` | PATCH | `/einstein/data-libraries/{id}` |
| `deleteLibrary` | DELETE | `/einstein/data-libraries/{id}` |
| `checkUploadReadiness` | GET | `/einstein/data-libraries/{id}/upload-readiness` |
| `requestUploadUrls` | POST | `/einstein/data-libraries/{id}/file-upload-urls` |
| `triggerIndexing` | POST | `/einstein/data-libraries/{id}/indexing` |
| `addFiles` | POST | `/einstein/data-libraries/{id}/files` |
| `getStatus` | GET | `/einstein/data-libraries/{id}/status` |
| `ADLS3Uploader.upload` | PUT | *(presigned S3 URL)* |

All Salesforce paths are prefixed with `/services/data/v66.0`.

---

## Support

For questions or issues with these classes, contact [rshekhar@salesforce.com](mailto:rshekhar@salesforce.com)