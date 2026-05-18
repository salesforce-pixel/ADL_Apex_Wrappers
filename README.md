# Agentforce Data Libraries Admin Console

A Salesforce Lightning Web Component and Apex solution for managing **Agentforce Data Libraries (ADL)** — the SFDRIVE-backed grounding sources that power Agentforce assistants. Provides an admin-friendly console for creating libraries, uploading files, watching indexing progress, and decommissioning libraries — all on top of a reusable Apex wrapper over the Agentforce Data Libraries REST API (v66.0 Beta).

> 📘 **Official API reference:** [Agentforce Data Libraries — Connect REST API](https://developer.salesforce.com/docs/atlas.en-us.chatterapi.meta/chatterapi/connect_resources_adl.htm)

---
## Documentation

- **[`README.md`](./README.md)** — Installation, org setup, console usage (this file)
- **[`DEVELOPER_GUIDE.md`](./DEVELOPER_GUIDE.md)** — Reusing `ADLClient` and `ADLS3Uploader` in your own Apex

---

## What This Solution Does

The **Agentforce Data Libraries Admin Console** is a full-stack Salesforce solution consisting of one Lightning Web Component (LWC), one orchestration controller, and two reusable wrapper classes (`ADLClient` and `ADLS3Uploader`). It provides a complete UI for managing the lifecycle of SFDRIVE grounding libraries used by Agentforce.

1. **Library discovery and live status** — On load, the console calls `getLibraries()`, which lists all SFDRIVE libraries in the org, hydrates each one with its full file roster, and overlays current indexing status (stage, overall state, last-updated timestamp). A 30-second background poller keeps non-terminal libraries fresh while the console is open.

2. **Library creation** — Admins create new SFDRIVE libraries from a guided modal. Master label, developer name (validated against `^[a-zA-Z][a-zA-Z0-9_]*$`), and an optional description are submitted as a JSON payload to avoid an LWC → Apex inner-class binding issue.

3. **File upload with full S3 round-trip** — Files are uploaded via drag-and-drop or file picker (PDF, HTML, TXT; up to 20 files per batch). Per the API, text and HTML files can be up to 4 MB and PDF files up to 100 MB; the current LWC enforces a single 4 MB ceiling across all types, so adjust `MAX_FILE_SIZE_BYTES` if you need PDFs larger than 4 MB. The controller checks upload readiness, requests presigned S3 URLs, uploads bytes directly to S3 via `ADLS3Uploader`, then submits the files for indexing — either provisioning the library for the first time (`triggerIndexing`) or appending to an already-indexed library (`addFiles`), depending on prior state.

4. **Indexing pipeline visualization** — The detail view renders the four-stage indexing pipeline (`DATA_LAKE_OBJECT` → `DATA_MODEL_OBJECT` → `SEARCH_INDEX` → `RETRIEVER`) with per-stage status dots and completion timestamps, driven by the normalised `/status` response shape.

5. **Cross-library file management** — A dedicated **Files** view aggregates every file across every library, surfaces duplicates (same filename in two or more libraries), and provides filtering by library, file type, uploader, and free-text search.

6. **Library deletion with safeguards** — Libraries can be deleted from the detail view via a type-to-confirm modal. Deleting an ADL removes the library record itself; the underlying Data Lake Object, Data Model Object, Search Index, and Retriever are **not** removed by this operation and may need to be cleaned up separately if you want to fully decommission the infrastructure.

The console presents three primary views — **Home** (greeting, metrics, recent libraries), **Libraries** (searchable, filterable grid), and **Files** (cross-library file table) — plus a per-library **Detail** view, in a clean Salesforce-native interface with Lightning Design System styling.

---

## Architecture

The solution is built in four layers, each with a single responsibility:

```
┌─────────────────────────────────────────────────────────────┐
│  agentforceDataLibraries (LWC)                              │
│  Renders UI, manages view state, base64-encodes uploads     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│  ADLConsoleController (Apex @AuraEnabled)                   │
│  Orchestrates multi-step flows, maps DTOs* to UI view models│
└─────────────────────────────────────────────────────────────┘
                              │
                ┌─────────────┴─────────────┐
                ▼                           ▼
┌──────────────────────────┐   ┌──────────────────────────────┐
│  ADLClient               │   │  ADLS3Uploader               │
│  Wraps the 10 ADL REST   │   │  Uploads bytes to AWS S3 via │
│  endpoints via Named     │   │  presigned PUT URLs (no auth │
│  Credential ADL_NC       │   │  header — signature in URL)  │
└──────────────────────────┘   └──────────────────────────────┘
```

`ADLClient` and `ADLS3Uploader` are intentionally separate — different domains (Salesforce vs. AWS S3), different auth models (OAuth bearer vs. URL-embedded Sig V4), and different failure modes (JSON errors vs. XML errors). Both are usable independently of this console — see **`DEVELOPER_GUIDE.md`** for reuse patterns.

> **\*DTO** = *Data Transfer Object*. In this codebase, the typed Apex inner classes inside `ADLClient` (e.g. `LibraryOutput`, `UploadUrlsOutput`, `StageDetail`) that mirror the JSON shapes the REST API sends and receives. They give callers compile-time-safe access to API fields instead of working with `Map<String, Object>`.

---

## Prerequisites

- **Salesforce CLI (sf CLI):** Latest version
- **Node.js:** Version 18 or higher
- **Git:** For version control
- A Salesforce org with the following enabled:
  - Einstein Data Libraries / Agentforce (with API access to `/services/data/v66.0/einstein/data-libraries` — see the [official Connect REST API reference](https://developer.salesforce.com/docs/atlas.en-us.chatterapi.meta/chatterapi/connect_resources_adl.htm))
  - Data Cloud (required for the underlying DLO / DMO / Search Index provisioning)

---

## Required Org Setup

Before any code is deployed or invoked, your org needs five pieces wired together:

```
External Client App  →  External Credential  →  Named Credential  →  Apex (callout:ADL_NC)
   (Consumer Key            (OAuth 2.0              (host +
    + Secret)                Client Creds            auth ref)
                             flow)
                                  ↑
                          Permission Set
                       (grants Principal access
                        to the invoking user)
```

Plus one Remote Site Setting for the S3 callouts. The eight steps below walk through each.

- **[`Screenshots`](./images/)** — Look at the setup screenshots of External Client App, External Credential and Named Credential here for reference

### Step 1 — Create an External Client App

The External Client App is what mints the OAuth tokens the Named Credential will use to call the ADL APIs.

**Setup → External Client Apps → External Client App Manager → New External Client App**

| Field | Value |
|---|---|
| External Client App Name | `ADL_Client_Application` |
| API Name | `ADL_Client_Application` |
| Contact Email | *(your email)* |
| Distribution State | `Local` |

**OAuth Settings** (enable OAuth):

| Field | Value |
|---|---|
| Callback URL | `https://login.salesforce.com/services/oauth2/success` |
| Selected OAuth Scopes | `Manage user data via APIs (api)`, `Manage user data via Web browsers (web)` |

**Flow Enablement**:

- ✅ **Enable Client Credentials Flow** — this is the only flow the wrapper needs.

Save and **Enable** the app. Status should show `Enabled`.

### Step 2 — Configure OAuth Policies on the External Client App

After saving, open **Policies** on the same app:

**OAuth Policies → Plugin Policies**:

| Field | Value |
|---|---|
| Permitted Users | `Admin approved users are pre-authorized` |

**OAuth Flows and External Client App Enhancements**:

- ✅ **Enable Client Credentials Flow**
- **Run As (Username)** — pick an integration user. **Every ADL API call will run as this user**, so it must have a profile or permission set granting access to the Agentforce Data Library APIs.

**Profile assignment** (further down the same page): add **System Administrator** (or any profile/permission set that should be allowed to *use* this app) to **Selected Profiles**.

### Step 3 — Capture the Consumer Key and Secret

Back on the **Settings** tab → **OAuth Settings** → click **Consumer Key and Secret**. Salesforce will display:

- **Consumer Key** (client_id)
- **Consumer Secret** (client_secret)

Copy both — you'll paste them in Step 4. Treat the secret like a password.

### Step 4 — Create the External Credential

The External Credential holds the OAuth configuration: which flow, which token endpoint, and the Principal that stores the client_id/secret.

**Setup → Named Credentials → External Credentials tab → New**

| Field | Value |
|---|---|
| Label | `ADL_EC` |
| Name | `ADL_EC` |
| Authentication Protocol | `OAuth 2.0` |
| Authentication Flow Type | `Client Credentials with Client Secret Flow` |
| Identity Provider URL | `https://<YOUR-MY-DOMAIN>.my.salesforce.com/services/oauth2/token` |
| Scope | *(leave blank)* |
| Pass client credentials in request body | ☐ *(unchecked — sent as Basic auth header)* |

Save.

**Add a Principal** (this is where the Consumer Key/Secret go):

Under the **Principals** section, click **New**:

| Field | Value |
|---|---|
| Parameter Name | `Credentials` |
| Sequence Number | `1` |
| Client ID | *(paste the Consumer Key from Step 3)* |
| Client Secret | *(paste the Consumer Secret from Step 3)* |

Save. The Principal should now show **Configured**.

> The `Parameter Name` value (`Credentials`) is what you'll later select inside the Permission Set when granting Principal Access. Keep it consistent.

### Step 5 — Create a Permission Set and grant External Credential access

Until a Permission Set grants access to the Principal you just created, *no user can use the External Credential* — and callouts will fail at the token-retrieval step. This is the single most common reason a freshly configured setup throws auth errors.

**Setup → Permission Sets → New**

| Field | Value |
|---|---|
| Label | `ADL Access` |
| API Name | `ADL_Access` |
| License | *(leave as `--None--` unless you need a license-specific one)* |

Save.

**On the new Permission Set's detail page**, find **External Credential Principal Access** (under the Apps section, or use the **Find Settings...** search box and type "External Credential"):

- Click **Edit**
- Move `ADL_EC - Credentials` from **Available External Credential Principals** to **Enabled External Credential Principals**
- Save

**Assign the Permission Set:**

- Click **Manage Assignments** → **Add Assignment**
- Add **every user who will invoke the Apex wrapper** — LWC users, Quick Action users, integration users running scheduled jobs, admins running `Execute Anonymous`, etc.

Without this assignment, the platform refuses to mint a token when the user's transaction reaches `callout:ADL_NC`, and the call fails before it even leaves the org.

> **Why this matters:** the Permission Set governs **who in this org is allowed to use the External Credential's Principal**. It is a *caller-side* check — every Apex invoker needs it. It is **unrelated to the Run As user** on the External Client App, which is a server-side identity choice (the user the ADL API will see the call as coming from). Don't conflate them:
>
> - **Permission Set assignment** answers: *"Is this calling user allowed to retrieve a token from this External Credential?"* → assign to every invoker.
> - **Run As user (Step 2)** answers: *"Once a token is issued, whose identity does it represent on the ADL service?"* → set once on the External Client App; not a user assignment.
>
> Forgetting to assign this permission set to invoking users is the #1 cause of "everything looks configured but callouts fail."

### Step 6 — Create the Named Credential

The Named Credential ties the host to the External Credential. The Apex calls it via `callout:ADL_NC`.

**Setup → Named Credentials → Named Credentials tab → New**

| Field | Value |
|---|---|
| Label | `ADL_NC` |
| Name | `ADL_NC` |
| URL | `https://<YOUR-MY-DOMAIN>.my.salesforce.com` |
| Enabled for Callouts | ✅ |
| External Credential | `ADL_EC` |
| Client Certificate | *(leave blank)* |

**Callout Options**:

- ✅ **Generate Authorization Header** — required; this is what injects the OAuth bearer token into every request.
- ☐ Allow Formulas in HTTP Header
- ☐ Allow Formulas in HTTP Body

Save.

> **Why the host URL is your own org:** the Agentforce Data Library REST API lives at `/services/data/v66.0/einstein/data-libraries` on your own My Domain — it's a first-party Salesforce API, not an external service. The OAuth flow is the org authenticating to itself on behalf of the integration user.

### Step 7 — Create the S3 Remote Site Setting

Required for `ADLS3Uploader`. S3 uploads do **not** go through a Named Credential — that would inject an `Authorization` header and break the AWS Sig V4 signature carried in the presigned URL.

**Setup → Remote Site Settings → New**

| Field | Value |
|---|---|
| Remote Site Name | `AWS_S3_Agentforce` |
| Remote Site URL | `https://s3.amazonaws.com` |
| Active | ✅ |

If your presigned URLs use a bucket-specific subdomain like `aws-prod1-useast1-cdp2-lakehouse-1.s3.amazonaws.com` and the generic entry above is not matched, add a second Remote Site Setting with that exact host. You can discover the exact host by inspecting the URLs returned from `requestUploadUrls` once everything else is wired up.

### Step 8 — Quick sanity check

Run this in **Developer Console → Execute Anonymous** as a user assigned the `ADL_Access` permission set:

```apex
ADLClient.LibraryListOutput out = ADLClient.listLibraries(null);
System.debug('Libraries: ' + out.totalSize);
```

A successful call confirms: External Client App is enabled, External Credential is configured, Named Credential is reachable, and the running user has permission set access. Any failure here will surface as an `ADLApiException` (HTTP-side) or callout exception (token retrieval) — fix that before moving on to file uploads.

### Configuration cross-reference

When you're done, the five pieces reference each other like this:

| Object | Name | References | Provides |
|---|---|---|---|
| External Client App | `ADL_Client_Application` | — | Consumer Key + Secret |
| External Credential | `ADL_EC` | Consumer Key/Secret (as Principal) | OAuth 2.0 token flow |
| Permission Set | `ADL_Access` | `ADL_EC - Credentials` | User-level access to the Principal |
| Named Credential | `ADL_NC` | `ADL_EC` | `callout:ADL_NC` for Apex |
| Remote Site Setting | `AWS_S3_Agentforce` | — | S3 host allowlisting |

---

## Installation

### Step 1: Clone the Repository

```bash
git clone https://github.com/salesforce-pixel/ADL_Apex_Wrappers.git
cd ADL_Apex_Wrappers
```

### Step 2: Authenticate with Your Salesforce Org

```bash
sf org login web -a targetOrg
```

> Replace `targetOrg` with your preferred alias for the org.

### Step 3: Deploy the Project

```bash
sf project deploy start -x manifest/package.xml -o targetOrg -l NoTestRun
```

This deploys the LWC (`agentforceDataLibraries`), the Apex classes (`ADLConsoleController`, `ADLClient`, `ADLS3Uploader`), and supporting metadata.

### Step 4: Complete the Org Setup

If you haven't already, follow the **Required Org Setup** section above. The wrapper classes will not function until all eight steps are complete.

### Step 5: Add the LWC to an App Page

1. Open **Lightning App Builder** (Setup → App Builder, or click the **Setup** gear → **Edit Page** on an existing page).
2. Create a new **App Page** with a **single-region, full-width** layout (the console is designed for full-screen use).
3. Locate **"Agentforce Data Libraries"** in the component panel on the left.
4. Drag and drop it onto the page.
5. Click **Save** and then **Activate**.

> The component is self-contained and requires no additional page-level configuration beyond placement.

---

## Usage Workflow

Once deployed, the typical admin workflow is:

| Step | View | Action |
|------|------|--------|
| 1. Discover | Home / Libraries | Browse existing libraries, see live status |
| 2. Create | Create modal | Provide master label, developer name, description |
| 3. Upload | Detail → Upload panel | Drop files or pick from filesystem (max 20 per batch — see Constraints for size limits) |
| 4. Index | Detail → Pipeline | Watch DLO → DMO → Search Index → Retriever stages complete |
| 5. Audit | Files view | Search across all libraries, spot duplicates, filter by type |
| 6. Decommission | Detail → Delete | Type-to-confirm deletion of the ADL record (underlying DLO/DMO/Search Index/Retriever are not removed) |

---

## Constraints and Limits

| Constraint | Value | Source |
|------------|-------|--------|
| Max files per upload batch | 20 | LWC (`MAX_FILES_PER_BATCH`) |
| Max file size — API limit | 4 MB for text/HTML, 100 MB for PDF | ADL REST API |
| Max file size — LWC enforced | 4 MB across all types | LWC (`MAX_FILE_SIZE_BYTES`) — adjust to raise the PDF ceiling |
| Files per library quota | 1,000 | LWC (`FILE_LIMIT_PER_LIBRARY`) |
| Supported file types | PDF, HTML, TXT | LWC validation |
| Presigned S3 URL TTL | ~15 minutes | AWS / ADLS3Uploader |
| Apex callout limit (per transaction) | 100 | Platform |
| Status poll interval | 30 seconds | LWC |
| Default callout timeout | 120 seconds | ADLClient / ADLS3Uploader |

---

## Repository Structure

```
force-app/
└── main/
    └── default/
        ├── lwc/
        │   └── agentforceDataLibraries/
        │       ├── agentforceDataLibraries.html   # Three-view shell + modals
        │       ├── agentforceDataLibraries.js     # View state, polling, upload pipeline
        │       └── agentforceDataLibraries.css    # Console styling
        └── classes/
            ├── ADLConsoleController.cls    # @AuraEnabled bridge between LWC and wrappers
            ├── ADLClient.cls               # Low-level wrapper over 10 ADL REST endpoints
            └── ADLS3Uploader.cls           # Presigned S3 URL uploader
DEVELOPER_GUIDE.md                          # Reuse guide for ADLClient + ADLS3Uploader
README.md                                   # This file
```

---

## Reusing the Wrapper Classes

Both `ADLClient` and `ADLS3Uploader` are designed to be reused in your own Apex code — Flows, Queueables, scheduled jobs, REST resources, or other LWCs. See **[`DEVELOPER_GUIDE.md`](./DEVELOPER_GUIDE.md)** for:

- A method-by-method reference for both classes
- When to use each class (and when not to)
- Worked examples: end-to-end upload, day-2 additions, polling, error handling
- The exception hierarchy and recommended catch patterns
- Common pitfalls (callout limits, presigned URL TTLs, signature errors)

---

## Implementation Note: JSON-String Payloads

Two `@AuraEnabled` methods — `createLibrary` and `uploadFiles` — accept their payloads as JSON strings (`requestJson`, `filesJson`) rather than as typed Apex inner classes. This sidesteps an observed LWC → Apex binding issue where LWC-provided objects arrive in Apex with non-null outer wrappers but blank inner fields, surfacing as misleading "Master label is required" errors even when the form is filled in correctly. The JSON path deserializes server-side and works reliably:

```javascript
await createLibrary({
    requestJson: JSON.stringify({ masterLabel, developerName, description })
});
```

If you build your own LWCs against `ADLConsoleController`, follow the same pattern for these two methods.

---

## Support

For questions or issues, contact [rshekhar@salesforce.com](mailto:rshekhar@salesforce.com)