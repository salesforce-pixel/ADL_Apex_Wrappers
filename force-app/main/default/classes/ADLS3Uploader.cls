/**
 * ADLS3Uploader — Uploads file bytes to AWS S3 using the presigned PUT URLs
 * returned by ADLClient.requestUploadUrls().
 *
 * Why separate from ADLClient:
 *   • Different domain (s3.amazonaws.com, not Salesforce)
 *   • Different auth model — signature is embedded in the URL query string;
 *     adding an Authorization header BREAKS the signature
 *   • Different failure modes — XML error bodies, not JSON; signature errors
 *     vs expiry vs missing headers all need distinct guidance
 *
 * Auth / setup:
 *   The presigned URL carries its own AWS Sig V4 signature in the query
 *   string — no Authorization header is needed (and adding one would break
 *   the signature). We just need Salesforce to permit the callout to AWS.
 *
 *   Add a Remote Site Setting:
 *     Name:   AWS_S3_Agentforce
 *     URL:    https://s3.amazonaws.com
 *     Active: ✅
 *
 *   If your presigned URL uses a bucket-specific subdomain like
 *   `aws-prod1-useast1-cdp2-lakehouse-1.s3.amazonaws.com` and the generic
 *   entry above is not matched, add a second Remote Site Setting with that
 *   exact host.
 *
 *   Note: do NOT route S3 callouts through a Named Credential. The Named
 *   Credential for ADL (`ADL_NC`) is for Salesforce-to-Salesforce auth and
 *   would inject an Authorization header that invalidates the AWS Sig V4
 *   signature carried in the presigned URL.
 *
 * Headers: pass through EXACTLY what ADLClient returned in the `headers` map
 * of the UploadUrl. No more, no less. The signature is computed over these
 * headers (see X-Amz-SignedHeaders in the URL); adding extras causes 403
 * SignatureDoesNotMatch.
 *
 * Body: must be raw binary. Use setBodyAsBlob, never setBody (string).
 *
 * URL lifetime: presigned URLs are short-lived (~15 minutes). Mint them and
 * upload in the same Apex transaction (or the same Queueable execution) to
 * avoid expiry. If you need to defer uploads, call requestUploadUrls() again
 * just before uploading.
 *
 * Callout limits: every PUT to S3 counts against the per-transaction callout
 * limit (currently 100). uploadAll() checks the remaining budget up-front and
 * fails fast rather than dying mid-batch. For large file sets, chunk across
 * Queueable executions.
 *
 * Exception model:
 *   S3Exception            — abstract parent; catch this for "anything from this class"
 *   ├── S3ClientException  — client-side validation (no HTTP call made)
 *   └── S3UploadException  — non-2xx response from S3
 *
 * Author: Rajeev Shekhar
 */
// 'without sharing' is intentional: this class performs no DML or SOQL, so the
// sharing keyword has no effect. We declare it explicitly to silence the
// PMD ApexSharingViolations rule and signal intent.
public without sharing class ADLS3Uploader {

    private static final Integer DEFAULT_TIMEOUT_MS = 120000;
    private static final Integer S3_PRESIGNED_URL_TTL_MIN = 15;

    // ---------------------------------------------------------------------
    // Exception hierarchy
    // ---------------------------------------------------------------------

    /**
     * Parent exception — catch this if you want to handle "anything from ADLS3Uploader".
     */
    public virtual class S3Exception extends Exception {
        public String fileName;
    }

    /**
     * Client-side validation failure — no HTTP call was made.
     */
    public class S3ClientException extends S3Exception {}

    /**
     * Non-2xx response from S3.
     */
    public class S3UploadException extends S3Exception {
        public Integer statusCode;
        public String awsErrorCode;   // parsed from XML body, e.g. SignatureDoesNotMatch
        public String responseBody;
    }

    // ---------------------------------------------------------------------
    // Result object — returned to callers so they can build the
    // UploadedFileInfo list for the next ADLClient call.
    // ---------------------------------------------------------------------

    public class UploadResult {
        public String fileName;
        public String filePath;   // pass to ADLClient.triggerIndexing / addFiles
        public Integer fileSize;  // Integer (not Long) — feeds straight into UploadedFileInfo
        public String eTag;       // from S3 response; useful for audit
    }

    // ---------------------------------------------------------------------
    // Single-file upload
    // ---------------------------------------------------------------------

    /**
     * PUT raw bytes to a presigned S3 URL.
     *
     * @param uploadUrl   The presigned URL from ADLClient.UploadUrl.uploadUrl.
     *                    Pass it through unchanged — do not URL-decode.
     * @param headers     The headers map from ADLClient.UploadUrl.headers.
     *                    Every entry MUST be sent; extras MUST NOT be added.
     * @param filePath    The filePath from ADLClient.UploadUrl.filePath.
     *                    Echoed back in the result for convenience.
     * @param fileName    The original file name (for the result + error context).
     * @param body        The raw file bytes.
     */
    public static UploadResult upload(
        String uploadUrl,
        Map<String, String> headers,
        String filePath,
        String fileName,
        Blob body
    ) {
        validateUploadArgs(uploadUrl, filePath, fileName, body);

        HttpRequest req = new HttpRequest();

        // Use the presigned URL directly — Remote Site Setting authorizes the host.
        // Do NOT route through a Named Credential; that would inject an
        // Authorization header and break the AWS Sig V4 signature.
        req.setEndpoint(uploadUrl);
        req.setMethod('PUT');
        req.setTimeout(DEFAULT_TIMEOUT_MS);
        req.setBodyAsBlob(body);

        // Apply ONLY the headers the API returned. No Authorization, no
        // Accept, no User-Agent overrides — anything extra risks breaking
        // the signature.
        if (headers != null) {
            for (String h : headers.keySet()) {
                if (String.isBlank(h)) {
                    throw newClientException('headers cannot contain blank header names', fileName);
                }
                req.setHeader(h, headers.get(h));
            }
        }

        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw buildS3Exception(res, fileName);
        }

        UploadResult r = new UploadResult();
        r.fileName = fileName;
        r.filePath = filePath;
        r.fileSize = body.size(); // Integer — feeds straight into UploadedFileInfo
        r.eTag = res.getHeader('ETag');

        return r;
    }

    /**
     * Convenience overload — accepts an ADLClient.UploadUrl directly so callers
     * don't have to unpack it. This is the typical usage pattern from a
     * higher-level orchestrator.
     */
    public static UploadResult upload(ADLClient.UploadUrl url, Blob body) {
        validateUploadUrl(url);
        return upload(url.uploadUrl, url.headers, url.filePath, url.fileName, body);
    }

    // ---------------------------------------------------------------------
    // Batch upload — sequential because Apex doesn't allow parallel callouts
    // ---------------------------------------------------------------------

    /**
     * Upload multiple files sequentially. Each blob is matched to an UploadUrl
     * by fileName. Throws on the first failure; preceding successful uploads
     * are NOT rolled back because S3 doesn't support that.
     *
     * Apex transaction callout limit is enforced up-front: if this batch
     * would exceed the remaining budget, we fail fast rather than dying
     * mid-loop with no recovery path. For large batches, chunk via Queueable.
     *
     * Duplicate fileName values are rejected because blobsByFileName cannot
     * disambiguate them. If duplicate names become valid for your use case,
     * key by filePath instead.
     */
    public static List<UploadResult> uploadAll(
        List<ADLClient.UploadUrl> urls,
        Map<String, Blob> blobsByFileName
    ) {
        validateUploadAllInputs(urls, blobsByFileName);

        Integer remaining = Limits.getLimitCallouts() - Limits.getCallouts();
        if (urls.size() > remaining) {
            throw newClientException(
                'Batch of ' + urls.size() + ' uploads would exceed remaining transaction '
                + 'callout budget (' + remaining + '/' + Limits.getLimitCallouts() + '). '
                + 'Chunk via Queueable.',
                null
            );
        }

        List<UploadResult> results = new List<UploadResult>();

        for (ADLClient.UploadUrl u : urls) {
            Blob body = blobsByFileName.get(u.fileName);

            if (body == null) {
                throw newClientException(
                    'No blob provided for fileName: ' + u.fileName,
                    u.fileName
                );
            }

            results.add(upload(u, body));
        }

        return results;
    }

    // ---------------------------------------------------------------------
    // Validation helpers
    // ---------------------------------------------------------------------

    private static void validateUploadArgs(
        String uploadUrl,
        String filePath,
        String fileName,
        Blob body
    ) {
        if (String.isBlank(uploadUrl)) {
            throw newClientException('uploadUrl is required', fileName);
        }
        if (String.isBlank(fileName)) {
            throw newClientException('fileName is required', fileName);
        }
        if (String.isBlank(filePath)) {
            throw newClientException('filePath is required', fileName);
        }
        if (body == null || body.size() == 0) {
            throw newClientException('body cannot be null or empty', fileName);
        }
    }

    private static void validateUploadUrl(ADLClient.UploadUrl url) {
        if (url == null) {
            throw newClientException('UploadUrl is required', null);
        }
        if (String.isBlank(url.uploadUrl)) {
            throw newClientException('UploadUrl.uploadUrl is required', url.fileName);
        }
        if (String.isBlank(url.fileName)) {
            throw newClientException('UploadUrl.fileName is required', null);
        }
        if (String.isBlank(url.filePath)) {
            throw newClientException('UploadUrl.filePath is required', url.fileName);
        }
    }

    private static void validateUploadAllInputs(
        List<ADLClient.UploadUrl> urls,
        Map<String, Blob> blobsByFileName
    ) {
        if (urls == null || urls.isEmpty()) {
            throw newClientException('urls cannot be null or empty', null);
        }
        if (blobsByFileName == null || blobsByFileName.isEmpty()) {
            throw newClientException('blobsByFileName cannot be null or empty', null);
        }

        Set<String> seenFileNames = new Set<String>();

        for (ADLClient.UploadUrl u : urls) {
            validateUploadUrl(u);

            if (seenFileNames.contains(u.fileName)) {
                throw newClientException(
                    'Duplicate fileName in upload URLs: ' + u.fileName
                    + '. uploadAll matches blobs by fileName and cannot disambiguate duplicates.',
                    u.fileName
                );
            }

            seenFileNames.add(u.fileName);
        }
    }

    // ---------------------------------------------------------------------
    // Error helpers
    // ---------------------------------------------------------------------

    private static S3UploadException buildS3Exception(HttpResponse res, String fileName) {
        S3UploadException ex = new S3UploadException();
        ex.statusCode = res.getStatusCode();
        ex.responseBody = res.getBody();
        ex.fileName = fileName;
        ex.awsErrorCode = parseAwsErrorCode(res.getBody());

        String remediation = remediationHint(ex.statusCode, ex.awsErrorCode);

        ex.setMessage(
            'S3 upload failed (' + ex.statusCode +
            (ex.awsErrorCode != null ? ' ' + ex.awsErrorCode : '') +
            ') for ' + (fileName != null ? fileName : '<unknown>') +
            (remediation != null ? ' — ' + remediation : '')
        );

        // Do not log the raw S3 response body by default. S3 XML errors can include
        // canonical request details and signed-header context that are useful for
        // triage but too sensitive/noisy for routine debug logs. The raw body remains
        // available on ex.responseBody for caller-controlled diagnostics.
        System.debug(LoggingLevel.WARN,
            'ADLS3Uploader upload failed: ' + ex.getMessage()
            + (ex.awsErrorCode != null ? ' | awsErrorCode=' + ex.awsErrorCode : '')
        );

        return ex;
    }

    /**
     * Parse the AWS error <Code> element from an S3 XML error body.
     * Uses Dom.Document so we don't break if AWS ever adds namespaces or
     * attributes to the element. Returns null if the body isn't parseable XML
     * or doesn't contain a Code element.
     *
     * S3 error shape:
     *   <Error><Code>SignatureDoesNotMatch</Code><Message>...</Message>...</Error>
     */
    @TestVisible
    private static String parseAwsErrorCode(String body) {
        if (String.isBlank(body)) return null;

        try {
            Dom.Document doc = new Dom.Document();
            doc.load(body);

            Dom.XmlNode root = doc.getRootElement();
            if (root == null) return null;

            // Walk direct children looking for an element named "Code"
            // using local name comparison, namespace-agnostic enough for
            // the expected S3 error shape.
            for (Dom.XmlNode child : root.getChildElements()) {
                if ('Code'.equalsIgnoreCase(child.getName())) {
                    String text = child.getText();
                    return String.isBlank(text) ? null : text.trim();
                }
            }
        } catch (Exception ignored) {
            // Not XML, or malformed — fall through to null.
        }

        return null;
    }

    private static String remediationHint(Integer status, String awsCode) {
        if (status == 403 && awsCode == 'SignatureDoesNotMatch') {
            return 'check that headers match the `headers` map returned by file-upload-urls, '
                + 'no Authorization header is being added, and the URL was not URL-decoded';
        }

        if (status == 403 && awsCode == 'AccessDenied') {
            return 'presigned URL likely expired (' + S3_PRESIGNED_URL_TTL_MIN
                + ' min TTL) — call requestUploadUrls again';
        }

        if (status == 400) {
            return 'body may have been sent as string instead of Blob — use setBodyAsBlob';
        }

        return null;
    }

    private static S3ClientException newClientException(String msg, String fileName) {
        S3ClientException ex = new S3ClientException();
        ex.fileName = fileName;
        ex.setMessage(msg);

        System.debug(LoggingLevel.WARN,
            'ADLS3Uploader validation failed'
            + (fileName != null ? ' for ' + fileName : '')
            + ': ' + msg
        );

        return ex;
    }
}