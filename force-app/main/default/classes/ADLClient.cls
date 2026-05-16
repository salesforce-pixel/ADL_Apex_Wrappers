/**
 * ADLClient — Low-level Apex wrapper over the Agentforce Data Library REST API.
 *
 * One static method per endpoint, with typed inner-class DTOs for request and
 * response bodies. This is Layer 1 of the wrapper stack: it does HTTP, JSON,
 * and error mapping, nothing more. Orchestration (ordering, polling, chunking)
 * belongs in a higher layer.
 *
 * Auth: uses UserInfo.getSessionId() + a Remote Site Setting for the org's
 * My Domain host. NOTE: this only works in synchronous contexts
 * (executeAnonymous, @AuraEnabled, VF controllers). It will NOT work in
 * @future, Queueable, Batch, or Scheduled Apex — those contexts return a
 * token without API access. For async, switch back to a Named Credential.
 *
 * S3 file upload (Step 4 in the API flow) is NOT in this class — see
 * ADLS3Uploader. The two are intentionally separate because they target
 * different domains, use different auth, and fail in different ways.
 *
 * API version: Salesforce REST v66.0 (Beta). The /status response shape uses
 * stageDetails when present (v67.0+) and falls back to the deprecated `stages`
 * map otherwise — normalized into stageDetails so callers see one shape.
 *
 * Exception model:
 *   ADLException            — abstract parent; catch this for "anything ADL"
 *   ├── ADLClientException  — client-side validation failures (no HTTP call made)
 *   └── ADLApiException     — HTTP non-2xx from the Salesforce API
 *
 * Author: Rajeev Shekhar
 */
public with sharing class ADLClient {

    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------

    @TestVisible
    private static String getInstanceUrl() {
        return URL.getOrgDomainUrl().toExternalForm();
    }

    @TestVisible
    private static final String BASE_PATH = '/services/data/v66.0/einstein/data-libraries';

    private static final Integer DEFAULT_TIMEOUT_MS = 120000; // matches max waitMaxTime

    // Compiled once at class load — used by validateCreateLibraryInput().
    private static final Pattern DEVELOPER_NAME_PATTERN =
        Pattern.compile('^[a-zA-Z][a-zA-Z0-9_]*$');

    // ---------------------------------------------------------------------
    // Exception hierarchy
    // ---------------------------------------------------------------------

    /**
     * Parent exception — catch this if you want to handle "anything from ADLClient".
     * Concrete subclasses below carry the context-specific fields.
     */
    public virtual class ADLException extends Exception {}

    /**
     * Client-side validation failure — no HTTP call was made.
     * Use this to distinguish "your inputs were bad" from "the API rejected them".
     */
    public class ADLClientException extends ADLException {}

    /**
     * HTTP error from the Salesforce ADL API (non-2xx response).
     */
    public class ADLApiException extends ADLException {
        public Integer statusCode;
        public String errorCode;     // Salesforce-style errorCode, when parseable
        public String responseBody;  // raw body, for triage
    }

    // ---------------------------------------------------------------------
    // Endpoint 1 — List libraries (discovery)
    // ---------------------------------------------------------------------

    /**
     * GET /einstein/data-libraries[?sourceType=...]
     * @param sourceType Optional filter: SFDRIVE, KNOWLEDGE, or RETRIEVER. Pass null for all.
     */
    public static LibraryListOutput listLibraries(String sourceType) {
        String path = BASE_PATH;
        if (String.isNotBlank(sourceType)) {
            path += '?sourceType=' + EncodingUtil.urlEncode(sourceType, 'UTF-8');
        }
        HttpResponse res = doCallout('GET', path, null);
        return (LibraryListOutput) deserializeOrThrow(res.getBody(), LibraryListOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 2 — Create library
    // ---------------------------------------------------------------------

    /**
     * POST /einstein/data-libraries
     */
    public static LibraryOutput createLibrary(CreateLibraryInput input) {
        validateCreateLibraryInput(input);
        HttpResponse res = doCallout('POST', BASE_PATH, JSON.serialize(input, true));
        return (LibraryOutput) deserializeOrThrow(res.getBody(), LibraryOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 3 — Get a single library
    // ---------------------------------------------------------------------

    /**
     * GET /einstein/data-libraries/{libraryId}
     */
    public static LibraryOutput getLibrary(String libraryId) {
        HttpResponse res = doCallout('GET', libraryPath(libraryId), null);
        return (LibraryOutput) deserializeOrThrow(res.getBody(), LibraryOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 4 — Update library
    // ---------------------------------------------------------------------

    /**
     * PATCH /einstein/data-libraries/{libraryId}
     */
    public static LibraryOutput updateLibrary(String libraryId, UpdateLibraryInput input) {
        validateUpdateLibraryInput(input);
        HttpResponse res = doCallout(
            'PATCH',
            libraryPath(libraryId),
            JSON.serialize(input, true)
        );
        return (LibraryOutput) deserializeOrThrow(res.getBody(), LibraryOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 5 — Delete library
    // ---------------------------------------------------------------------

    /**
     * DELETE /einstein/data-libraries/{libraryId}
     * Returns true on HTTP 204.
     */
    public static Boolean deleteLibrary(String libraryId) {
        HttpResponse res = doCallout('DELETE', libraryPath(libraryId), null);
        return res.getStatusCode() == 204;
    }

    // ---------------------------------------------------------------------
    // Endpoint 6 — Upload readiness
    // ---------------------------------------------------------------------

    /**
     * GET /einstein/data-libraries/{libraryId}/upload-readiness[?waitMaxTime=N]
     * @param waitMaxTimeMs Server-side wait, 0–120000. Pass null or 0 for immediate check.
     */
    public static UploadReadinessOutput checkUploadReadiness(String libraryId, Integer waitMaxTimeMs) {
        validateWaitMaxTimeMs(waitMaxTimeMs);

        String path = libraryPath(libraryId) + '/upload-readiness';
        if (waitMaxTimeMs != null && waitMaxTimeMs > 0) {
            path += '?waitMaxTime=' + waitMaxTimeMs;
        }

        HttpResponse res = doCallout('GET', path, null);
        return (UploadReadinessOutput) deserializeOrThrow(res.getBody(), UploadReadinessOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 7 — Request presigned upload URLs
    // ---------------------------------------------------------------------

    /**
     * POST /einstein/data-libraries/{libraryId}/file-upload-urls
     */
    public static UploadUrlsOutput requestUploadUrls(String libraryId, List<String> fileNames) {
        validateFileNames(fileNames);

        FileUploadUrlsInput input = new FileUploadUrlsInput();
        input.files = new List<FileInfoInput>();

        for (String fn : fileNames) {
            FileInfoInput fi = new FileInfoInput();
            fi.fileName = fn;
            input.files.add(fi);
        }

        HttpResponse res = doCallout(
            'POST',
            libraryPath(libraryId) + '/file-upload-urls',
            JSON.serialize(input, true)
        );
        return (UploadUrlsOutput) deserializeOrThrow(res.getBody(), UploadUrlsOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 8 — Trigger indexing (initial provisioning)
    // ---------------------------------------------------------------------

    /**
     * POST /einstein/data-libraries/{libraryId}/indexing
     */
    public static ProvisionOutput triggerIndexing(String libraryId, List<UploadedFileInfo> uploadedFiles) {
        validateUploadedFiles(uploadedFiles);

        ProvisionInput input = new ProvisionInput();
        input.uploadedFiles = uploadedFiles;

        HttpResponse res = doCallout(
            'POST',
            libraryPath(libraryId) + '/indexing',
            JSON.serialize(input, true)
        );
        return (ProvisionOutput) deserializeOrThrow(res.getBody(), ProvisionOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 9 — Day-2 add files
    // ---------------------------------------------------------------------

    /**
     * POST /einstein/data-libraries/{libraryId}/files
     */
    public static AddFilesOutput addFiles(String libraryId, List<UploadedFileInfo> uploadedFiles) {
        validateUploadedFiles(uploadedFiles);

        AddFilesInput input = new AddFilesInput();
        input.uploadedFiles = uploadedFiles;

        HttpResponse res = doCallout(
            'POST',
            libraryPath(libraryId) + '/files',
            JSON.serialize(input, true)
        );
        return (AddFilesOutput) deserializeOrThrow(res.getBody(), AddFilesOutput.class);
    }

    // ---------------------------------------------------------------------
    // Endpoint 10 — Indexing status
    // ---------------------------------------------------------------------

    /**
     * GET /einstein/data-libraries/{libraryId}/status
     *
     * Handles the v66→v67 transition: builds stageDetails from the deprecated
     * `stages` map when the array form isn't present, so callers always see
     * stageDetails populated when indexingStatus is present.
     */
    public static StatusOutput getStatus(String libraryId) {
        HttpResponse res = doCallout('GET', libraryPath(libraryId) + '/status', null);
        return buildStatusOutput(res.getBody());
    }

    // ---------------------------------------------------------------------
    // HTTP plumbing
    // ---------------------------------------------------------------------

    @TestVisible
    private static HttpResponse doCallout(String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        //req.setEndpoint(getInstanceUrl() + path);
        req.setMethod(method);
        req.setTimeout(DEFAULT_TIMEOUT_MS);
        req.setEndpoint('callout:ADL_NC' + path);
        req.setHeader('Accept', 'application/json');

        if (body != null) {
            req.setHeader('Content-Type', 'application/json');
            req.setBody(body);
        }

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw buildApiException(method, path, res);
        }
        return res;
    }

    private static ADLApiException buildApiException(String method, String path, HttpResponse res) {
        ADLApiException ex = new ADLApiException();
        ex.statusCode = res.getStatusCode();
        ex.responseBody = res.getBody();

        String msg = 'ADL API error ' + res.getStatusCode();

        try {
            Object parsed = JSON.deserializeUntyped(res.getBody());

            if (parsed instanceof List<Object>) {
                List<Object> arr = (List<Object>) parsed;
                if (!arr.isEmpty() && arr[0] instanceof Map<String, Object>) {
                    Map<String, Object> first = (Map<String, Object>) arr[0];
                    if (first.get('errorCode') != null) ex.errorCode = String.valueOf(first.get('errorCode'));
                    if (first.get('message') != null) msg = String.valueOf(first.get('message'));
                }
            } else if (parsed instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) parsed;
                if (m.get('errorCode') != null) ex.errorCode = String.valueOf(m.get('errorCode'));
                if (m.get('message') != null) msg = String.valueOf(m.get('message'));
            }
        } catch (Exception ignored) {
            // Body wasn't JSON — keep generic message.
        }

        ex.setMessage(msg + (String.isNotBlank(ex.errorCode) ? ' [' + ex.errorCode + ']' : ''));

        System.debug(LoggingLevel.WARN,
            'ADLClient ' + method + ' ' + path + ' failed: ' + ex.getMessage()
            + (String.isNotBlank(ex.responseBody) ? ' | body=' + ex.responseBody.abbreviate(500) : '')
        );

        return ex;
    }

    private static ADLClientException newClientException(String msg) {
        ADLClientException ex = new ADLClientException();
        ex.setMessage(msg);
        System.debug(LoggingLevel.WARN, 'ADLClient validation failed: ' + msg);
        return ex;
    }

    /**
     * Deserialize a JSON body into the given type, wrapping any JSONException
     * as an ADLApiException so callers don't need to catch both layers.
     * A 2xx response with the wrong shape is still an API-side problem.
     */
    private static Object deserializeOrThrow(String body, Type targetType) {
        try {
            return JSON.deserialize(body, targetType);
        } catch (Exception e) {
            ADLApiException ex = new ADLApiException();
            ex.statusCode = 200; // we got here from a 2xx
            ex.responseBody = body;
            ex.setMessage(
                'Unexpected response shape for ' + targetType.getName() + ': ' + e.getMessage()
            );
            System.debug(LoggingLevel.WARN, 'ADLClient deserialize failed: ' + ex.getMessage());
            throw ex;
        }
    }

    // ---------------------------------------------------------------------
    // Validation helpers
    // ---------------------------------------------------------------------

    private static String pathEncode(String value) {
        return EncodingUtil.urlEncode(value, 'UTF-8').replace('+', '%20');
    }

    private static String libraryPath(String libraryId) {
        requireLibraryId(libraryId);
        return BASE_PATH + '/' + pathEncode(libraryId);
    }

    private static void requireLibraryId(String id) {
        if (String.isBlank(id)) {
            throw newClientException('libraryId is required');
        }
    }

    private static void requireNotNull(Object value, String fieldName) {
        if (value == null) {
            throw newClientException(fieldName + ' cannot be null');
        }
    }

    // Note: Apex Lists are not covariant (List<String> is not List<Object>),
    // so we can't write a single requireNotEmpty(List<Object>...) helper that
    // accepts any list. The two specific overloads below cover the cases we need.
   private static void requireNotEmpty(List<String> values, String fieldName) {
        if (values == null || values.isEmpty()) {
            throw newClientException(fieldName + ' cannot be null or empty');
        }
    }

    private static void requireNotEmpty(List<UploadedFileInfo> values, String fieldName) {
        if (values == null || values.isEmpty()) {
            throw newClientException(fieldName + ' cannot be null or empty');
        }
    }

    private static void validateWaitMaxTimeMs(Integer waitMaxTimeMs) {
        if (waitMaxTimeMs == null) return;

        if (waitMaxTimeMs < 0 || waitMaxTimeMs > 120000) {
            throw newClientException('waitMaxTimeMs must be 0-120000');
        }
    }

    private static void validateFileNames(List<String> fileNames) {
        requireNotEmpty(fileNames, 'fileNames');

        for (String fn : fileNames) {
            if (String.isBlank(fn)) {
                throw newClientException('fileNames cannot contain blank values');
            }
        }
    }

    private static void validateUploadedFiles(List<UploadedFileInfo> uploadedFiles) {
        requireNotEmpty(uploadedFiles, 'uploadedFiles');

        for (UploadedFileInfo f : uploadedFiles) {
            if (f == null) {
                throw newClientException('uploadedFiles cannot contain null entries');
            }
            if (String.isBlank(f.filePath)) {
                throw newClientException('uploadedFiles.filePath is required');
            }
            if (f.fileSize == null || f.fileSize < 0) {
                throw newClientException('uploadedFiles.fileSize must be zero or positive');
            }
        }
    }

    private static void validateCreateLibraryInput(CreateLibraryInput input) {
        requireNotNull(input, 'CreateLibraryInput');

        if (String.isBlank(input.masterLabel)) {
            throw newClientException('masterLabel is required');
        }
        if (String.isBlank(input.developerName)) {
            throw newClientException('developerName is required');
        }

        // Same pattern the API enforces server-side — fail fast client-side.
        if (!DEVELOPER_NAME_PATTERN.matcher(input.developerName).matches()) {
            throw newClientException(
                'developerName must match ^[a-zA-Z][a-zA-Z0-9_]*$ (letter first, then letters/digits/underscores)'
            );
        }

        if (input.masterLabel.length() > 80) {
            throw newClientException('masterLabel max 80 chars');
        }
        if (input.developerName.length() > 80) {
            throw newClientException('developerName max 80 chars');
        }
        if (input.description != null && input.description.length() > 255) {
            throw newClientException('description max 255 chars');
        }
    }

    private static void validateUpdateLibraryInput(UpdateLibraryInput input) {
        requireNotNull(input, 'UpdateLibraryInput');

        if (input.masterLabel != null && input.masterLabel.length() > 80) {
            throw newClientException('masterLabel max 80 chars');
        }
        if (input.description != null && input.description.length() > 255) {
            throw newClientException('description max 255 chars');
        }
    }

    // ---------------------------------------------------------------------
    // Status response normalization
    // ---------------------------------------------------------------------

    /**
     * Build a StatusOutput from the raw JSON body, normalizing v66 and v67+
     * shapes into a single representation populated in stageDetails.
     */
    private static StatusOutput buildStatusOutput(String body) {
        Object parsed;

        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (Exception e) {
            ADLApiException ex = new ADLApiException();
            ex.statusCode = 200;
            ex.responseBody = body;
            ex.setMessage('Unexpected /status response shape: ' + e.getMessage());
            System.debug(LoggingLevel.WARN, 'ADLClient status parse failed: ' + ex.getMessage());
            throw ex;
        }

        if (!(parsed instanceof Map<String, Object>)) {
            ADLApiException ex = new ADLApiException();
            ex.statusCode = 200;
            ex.responseBody = body;
            ex.setMessage('Unexpected /status response shape: root was not a JSON object');
            System.debug(LoggingLevel.WARN, 'ADLClient status parse failed: ' + ex.getMessage());
            throw ex;
        }

        Map<String, Object> root = (Map<String, Object>) parsed;

        StatusOutput out = new StatusOutput();

        Object idxObj = root.get('indexingStatus');
        if (idxObj == null) {
            return out;
        }

        if (!(idxObj instanceof Map<String, Object>)) {
            ADLApiException ex = new ADLApiException();
            ex.statusCode = 200;
            ex.responseBody = body;
            ex.setMessage('Unexpected /status response shape: indexingStatus was not a JSON object');
            System.debug(LoggingLevel.WARN, 'ADLClient status parse failed: ' + ex.getMessage());
            throw ex;
        }

        Map<String, Object> idx = (Map<String, Object>) idxObj;

        IndexingStatus is = new IndexingStatus();
        is.stageDetails = new List<StageDetail>();
        is.libraryId     = idx.get('libraryId') == null ? null : String.valueOf(idx.get('libraryId'));
        is.status        = idx.get('status') == null ? null : String.valueOf(idx.get('status'));
        is.currentStage  = idx.get('currentStage') == null ? null : String.valueOf(idx.get('currentStage'));
        is.lastUpdatedAt = toLong(idx.get('lastUpdatedAt'));

        // Prefer the v67+ stageDetails array if present.
        Object stageDetailsObj = idx.get('stageDetails');
        if (stageDetailsObj instanceof List<Object>) {
            for (Object o : (List<Object>) stageDetailsObj) {
                if (o instanceof Map<String, Object>) {
                    is.stageDetails.add(toStageDetail((Map<String, Object>) o, null));
                }
            }
        } else {
            // Fall back to the v66 `stages` map, projecting it into stageDetails.
            Object stagesObj = idx.get('stages');
            if (stagesObj instanceof Map<String, Object>) {
                Map<String, Object> stages = (Map<String, Object>) stagesObj;

                for (String stageName : stages.keySet()) {
                    Object v = stages.get(stageName);
                    if (v instanceof Map<String, Object>) {
                        is.stageDetails.add(toStageDetail((Map<String, Object>) v, stageName));
                    }
                }
            }
        }

        out.indexingStatus = is;
        return out;
    }

    private static StageDetail toStageDetail(Map<String, Object> m, String stageNameFallback) {
        StageDetail d = new StageDetail();
        Object stageObj = m.get('stage');

        d.stage       = stageObj == null ? stageNameFallback : String.valueOf(stageObj);
        d.status      = m.get('status') == null ? null : String.valueOf(m.get('status'));
        d.completedAt = toLong(m.get('completedAt'));

        return d;
    }

    private static Long toLong(Object o) {
        if (o == null) return null;
        if (o instanceof Long) return (Long) o;
        if (o instanceof Integer) return (Long)(Integer) o;
        if (o instanceof Decimal) return ((Decimal) o).longValue();

        try {
            return Long.valueOf(String.valueOf(o));
        } catch (Exception ignored) {
            return null;
        }
    }

    // =====================================================================
    // DTOs — Request inputs
    // =====================================================================

    public class CreateLibraryInput {
        public String masterLabel;
        public String developerName;
        public String description;
        public String dataSpaceScopeId; // omit unless using non-default dataspace (not currently supported)
        public GroundingSourceInput groundingSource;
    }

    public class UpdateLibraryInput {
        public String masterLabel;
        public String description;
        public GroundingSourceInput groundingSource;
    }

    public class GroundingSourceInput {
        public String sourceType; // SFDRIVE | KNOWLEDGE | RETRIEVER
        public KnowledgeConfigInput knowledgeConfig;
        public String retrieverId;
    }

    public class KnowledgeConfigInput {
        public String primaryIndexField1;
        public String primaryIndexField2;
        public List<String> contentFields;
        public Boolean isRestrictToPublicArticle;
        public Boolean isDataCategoryRuleEnabled;
        public List<String> dataCategorySelectionIds;
    }

    public class FileUploadUrlsInput {
        public List<FileInfoInput> files;
    }

    public class FileInfoInput {
        public String fileName;
    }

    public class ProvisionInput {
        public List<UploadedFileInfo> uploadedFiles;
    }

    public class AddFilesInput {
        public List<UploadedFileInfo> uploadedFiles;
    }

    public class UploadedFileInfo {
        public String filePath;
        public Integer fileSize; // Integer (not Long) to avoid Apex JSON serializer emitting "181867.0"

        public UploadedFileInfo() {}

        public UploadedFileInfo(String filePath, Integer fileSize) {
            this.filePath = filePath;
            this.fileSize = fileSize;
        }
    }

    // =====================================================================
    // DTOs — Responses
    // =====================================================================

    public class LibraryListOutput {
        public List<LibraryOutput> libraries;
        public Integer totalSize;
    }

    public class LibraryOutput {
        public String libraryId;
        public String masterLabel;
        public String developerName;
        public String description;
        public String sourceType;
        public String dataSpaceScopeId;
        public GroundingSourceOutput groundingSource;
    }

    public class GroundingSourceOutput {
        public String groundingSourceType;
        public List<GroundingFileRef> groundingFileRefs;
    }

    public class GroundingFileRef {
        public String fileId;
        public String fileName;
        public String filePath;
        public Decimal fileSize;
        public String groundingSourceId;
        public String createdDate;
        public String createdBy;
        public String createdById;
    }

    public class UploadReadinessOutput {
        public String libraryId;
        public String sourceType;
        public Boolean ready;
        public String message;
    }

    public class UploadUrlsOutput {
        public String libraryId;
        public List<UploadUrl> uploadUrls;
    }

    public class UploadUrl {
        public String fileName;
        public String filePath;
        public String uploadUrl;
        public Map<String, String> headers;
    }

    public class ProvisionOutput {
        public String libraryId;
        public String sourceType;
        public String status;          // LibraryStatusEnum
        public String message;
        public Integer filesAccepted;  // SFDRIVE only
    }

    public class AddFilesOutput {
        public String libraryId;
        public Integer filesAccepted;
        public List<GroundingFileRef> groundingFileRefs;
    }

    public class StatusOutput {
        public IndexingStatus indexingStatus;
    }

    public class IndexingStatus {
        public String libraryId;
        public String status;        // LibraryStatusEnum
        public String currentStage;  // GroundingSourceStageEnum
        public Long lastUpdatedAt;
        public List<StageDetail> stageDetails; // normalized from v67+ stageDetails or legacy v66 stages
    }

    public class StageDetail {
        public String stage;       // populated from map key when API returned legacy `stages` shape
        public String status;      // SCHEDULED | IN_PROGRESS | SUCCESS | FAILED
        public Long completedAt;
    }

    // =====================================================================
    // Convenience: terminal-state check
    // =====================================================================

    /**
     * True when the overall library status is one of READY, FAILED, INCOMPLETE,
     * NO_SOURCES — i.e. polling should stop.
     */
    public static Boolean isTerminal(String status) {
        if (String.isBlank(status)) return false;

        return status == 'READY'
            || status == 'FAILED'
            || status == 'INCOMPLETE'
            || status == 'NO_SOURCES';
    }
}