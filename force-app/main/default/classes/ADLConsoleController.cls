public with sharing class ADLConsoleController {
    // ---------------------------------------------------------------------
    // LWC DTOs
    // ---------------------------------------------------------------------

    public class LibraryVM {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String devName;
        @AuraEnabled public String description;
        @AuraEnabled public String sourceType;
        @AuraEnabled public String dataSpaceScopeId;

        @AuraEnabled public String status;
        @AuraEnabled public String currentStage;
        @AuraEnabled public Long lastUpdatedAt;

        @AuraEnabled public List<StageVM> stages;
        @AuraEnabled public List<FileVM> files;

        @AuraEnabled public Boolean hydrationFailed;
        @AuraEnabled public String hydrationMessage;
        @AuraEnabled public Boolean statusFailed;
        @AuraEnabled public String statusMessage;
    }

    public class StageVM {
        @AuraEnabled public String stage;
        @AuraEnabled public String status;
        @AuraEnabled public Long completedAt;
    }

    public class FileVM {
        @AuraEnabled public String fileId;
        @AuraEnabled public String fileName;
        @AuraEnabled public String filePath;
        @AuraEnabled public Long fileSize;
        @AuraEnabled public String groundingSourceId;
        @AuraEnabled public String createdDate;
        @AuraEnabled public String createdBy;
        @AuraEnabled public String createdById;
    }

    // Kept as the deserialization target. The LWC no longer binds to this
    // class directly via @AuraEnabled — see createLibrary below for the
    // explanation. We accept a JSON string and deserialize manually.
    public class CreateLibraryRequest {
        @AuraEnabled public String masterLabel;
        @AuraEnabled public String developerName;
        @AuraEnabled public String description;
    }

    // Same story — kept for documentation and deserialization, not for
    // direct LWC binding.
    public class UploadFileRequest {
        @AuraEnabled public String fileName;
        @AuraEnabled public String base64Data;
    }

    public class UploadResultVM {
        @AuraEnabled public String libraryId;
        @AuraEnabled public Integer filesAccepted;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
        @AuraEnabled public List<FileVM> files;
    }

    public class DeleteResultVM {
        @AuraEnabled public String libraryId;
        @AuraEnabled public Boolean deleted;
        @AuraEnabled public String message;
    }

    // ---------------------------------------------------------------------
    // LWC API
    // ---------------------------------------------------------------------

    @AuraEnabled
    public static List<LibraryVM> getLibraries() {
        try {
            ADLClient.LibraryListOutput output = ADLClient.listLibraries('SFDRIVE');

            List<LibraryVM> results = new List<LibraryVM>();
            if (output == null || output.libraries == null || output.libraries.isEmpty()) {
                return results;
            }

            for (ADLClient.LibraryOutput listLib : output.libraries) {
                if (listLib == null) {
                    continue;
                }

                ADLClient.LibraryOutput sourceLib = listLib;
                Boolean hydrationFailed = false;
                String hydrationMessage;

                try {
                    if (String.isNotBlank(listLib.libraryId)) {
                        ADLClient.LibraryOutput detailLib = ADLClient.getLibrary(listLib.libraryId);
                        if (detailLib != null) {
                            sourceLib = mergeLibraryOutputs(listLib, detailLib);
                        }
                    }
                } catch (Exception hydrateEx) {
                    hydrationFailed = true;
                    hydrationMessage = hydrateEx.getMessage();

                    System.debug(
                        LoggingLevel.WARN,
                        'ADLConsoleController hydration failed for library ' +
                        listLib.libraryId + ': ' + hydrationMessage
                    );
                }

                LibraryVM vm = toLibraryVM(sourceLib);
                vm.hydrationFailed = hydrationFailed;
                vm.hydrationMessage = hydrationMessage;

                applyStatusSafely(vm);

                results.add(vm);
            }

            return results;
        } catch (Exception e) {
            throw handled(e);
        }
    }

    @AuraEnabled
    public static LibraryVM getLibrary(String libraryId) {
        try {
            if (String.isBlank(libraryId)) {
                throw new AuraHandledException('libraryId is required.');
            }

            ADLClient.LibraryOutput lib = ADLClient.getLibrary(libraryId);
            LibraryVM vm = toLibraryVM(lib);

            applyStatusSafely(vm);

            return vm;
        } catch (Exception e) {
            throw handled(e);
        }
    }

    /**
     * Create a library.
     *
     * Accepts the form payload as a JSON string instead of as
     * CreateLibraryRequest directly. Same workaround as uploadFiles below:
     * LWC → Apex parameter binding for inner classes with only @AuraEnabled
     * fields has been observed in this org to silently produce instances
     * with null fields. The outer object arrives non-null, but masterLabel /
     * developerName / description come through as blank — which is exactly
     * the "MasterLabel is required" failure being seen.
     *
     * JSON.deserialize in Apex doesn't go through the LWC parameter binding
     * layer at all and works reliably.
     *
     * Expected JSON shape:
     *   {"masterLabel": "...", "developerName": "...", "description": "..."}
     */
    @AuraEnabled
    public static LibraryVM createLibrary(String requestJson) {
        try {
            if (String.isBlank(requestJson)) {
                throw new AuraHandledException('Create request is required.');
            }

            System.debug(
                LoggingLevel.INFO,
                'ADLConsoleController.createLibrary received payload length=' +
                requestJson.length()
            );

            CreateLibraryRequest request;
            try {
                request = (CreateLibraryRequest) JSON.deserialize(
                    requestJson,
                    CreateLibraryRequest.class
                );
            } catch (Exception parseEx) {
                throw new AuraHandledException(
                    'Could not parse create request: ' + parseEx.getMessage()
                );
            }

            if (request == null) {
                throw new AuraHandledException('Create request is required.');
            }

            if (String.isBlank(request.masterLabel)) {
                throw new AuraHandledException('Master label is required.');
            }

            if (String.isBlank(request.developerName)) {
                throw new AuraHandledException('Developer name is required.');
            }

            ADLClient.CreateLibraryInput input = new ADLClient.CreateLibraryInput();
            input.masterLabel = request.masterLabel.trim();
            input.developerName = request.developerName.trim();
            input.description = String.isBlank(request.description)
                ? null
                : request.description.trim();

            input.groundingSource = new ADLClient.GroundingSourceInput();
            input.groundingSource.sourceType = 'SFDRIVE';

            ADLClient.LibraryOutput created = ADLClient.createLibrary(input);

            LibraryVM vm = toLibraryVM(created);

            try {
                applyStatus(vm, ADLClient.getStatus(created.libraryId));
            } catch (Exception ignored) {
                vm.status = 'IN_PROGRESS';
                vm.currentStage = 'DATA_LAKE_OBJECT';
                vm.lastUpdatedAt = DateTime.now().getTime();
                vm.stages = defaultStages('DATA_LAKE_OBJECT');
            }

            return vm;
        } catch (Exception e) {
            throw handled(e);
        }
    }

    /**
     * Delete a library. Tears down the DLO, DMO, search index, and retriever
     * server-side — no undo. The destructive UX (type-to-confirm) lives in
     * the LWC; Apex just verifies inputs and calls the API.
     */
    @AuraEnabled
    public static DeleteResultVM deleteLibrary(String libraryId) {
        try {
            if (String.isBlank(libraryId)) {
                throw new AuraHandledException('libraryId is required.');
            }

            Boolean ok = ADLClient.deleteLibrary(libraryId);

            DeleteResultVM result = new DeleteResultVM();
            result.libraryId = libraryId;
            result.deleted = ok;
            result.message = ok
                ? 'Library deleted.'
                : 'Library delete did not return success.';

            if (!ok) {
                throw new AuraHandledException(result.message);
            }

            return result;
        } catch (Exception e) {
            throw handled(e);
        }
    }

    /**
     * Accepts the file batch as a JSON string instead of List<UploadFileRequest>.
     * See createLibrary for the same workaround rationale — LWC → Apex
     * inner-class binding drops fields silently in this org.
     *
     * Expected JSON shape:
     *   [{"fileName": "x.pdf", "base64Data": "..."}, ...]
     */
    @AuraEnabled
    public static UploadResultVM uploadFiles(String libraryId, String filesJson) {
        try {
            if (String.isBlank(libraryId)) {
                throw new AuraHandledException('libraryId is required.');
            }

            if (String.isBlank(filesJson)) {
                throw new AuraHandledException('Select at least one file.');
            }

            System.debug(
                LoggingLevel.INFO,
                'ADLConsoleController.uploadFiles received payload length=' + filesJson.length()
            );

            List<UploadFileRequest> files;
            try {
                files = (List<UploadFileRequest>) JSON.deserialize(
                    filesJson,
                    List<UploadFileRequest>.class
                );
            } catch (Exception parseEx) {
                throw new AuraHandledException(
                    'Could not parse upload payload: ' + parseEx.getMessage()
                );
            }

            if (files == null || files.isEmpty()) {
                throw new AuraHandledException('Select at least one file.');
            }

            List<String> fileNames = new List<String>();
            Map<String, Blob> blobsByFileName = new Map<String, Blob>();
            Set<String> seen = new Set<String>();

            for (Integer i = 0; i < files.size(); i++) {
                UploadFileRequest f = files[i];

                if (f == null) {
                    throw new AuraHandledException(
                        'Upload request contained an empty file entry at index ' + i + '.'
                    );
                }

                if (String.isBlank(f.fileName)) {
                    throw new AuraHandledException(
                        'Upload request contained a file with no name at index ' + i + '.'
                    );
                }

                if (String.isBlank(f.base64Data)) {
                    throw new AuraHandledException(
                        'Upload request contained no file body for: ' + f.fileName
                    );
                }

                String cleanFileName = f.fileName.trim();

                if (seen.contains(cleanFileName)) {
                    throw new AuraHandledException('Duplicate file name in upload batch: ' + cleanFileName);
                }

                Blob body;
                try {
                    body = EncodingUtil.base64Decode(f.base64Data);
                } catch (Exception decodeEx) {
                    throw new AuraHandledException('Could not decode file: ' + cleanFileName);
                }

                seen.add(cleanFileName);
                fileNames.add(cleanFileName);
                blobsByFileName.put(cleanFileName, body);
            }

            ADLClient.UploadReadinessOutput readiness =
                ADLClient.checkUploadReadiness(libraryId, 0);

            if (readiness != null && readiness.ready == false) {
                throw new AuraHandledException(
                    String.isNotBlank(readiness.message)
                        ? readiness.message
                        : 'This library is not ready to receive files yet.'
                );
            }

            ADLClient.UploadUrlsOutput urlsOutput =
                ADLClient.requestUploadUrls(libraryId, fileNames);

            List<ADLClient.UploadUrl> urls =
                urlsOutput == null ? null : urlsOutput.uploadUrls;

            if (urls == null || urls.isEmpty()) {
                throw new AuraHandledException('No upload URLs were returned by the ADL API.');
            }

            List<ADLS3Uploader.UploadResult> s3Results =
                ADLS3Uploader.uploadAll(urls, blobsByFileName);

            List<ADLClient.UploadedFileInfo> uploadedFiles =
                new List<ADLClient.UploadedFileInfo>();

            for (ADLS3Uploader.UploadResult r : s3Results) {
                uploadedFiles.add(new ADLClient.UploadedFileInfo(r.filePath, r.fileSize));
            }

            Boolean existingFiles = hasExistingFiles(libraryId);

            UploadResultVM result = new UploadResultVM();
            result.libraryId = libraryId;
            result.files = new List<FileVM>();

            if (existingFiles) {
                ADLClient.AddFilesOutput addOutput =
                    ADLClient.addFiles(libraryId, uploadedFiles);

                result.filesAccepted = addOutput == null ? uploadedFiles.size() : addOutput.filesAccepted;
                result.status = 'FILES_ACCEPTED';
                result.message = 'Files were uploaded and submitted for indexing.';

                if (addOutput != null && addOutput.groundingFileRefs != null) {
                    result.files = toFileVMs(addOutput.groundingFileRefs);
                }
            } else {
                ADLClient.ProvisionOutput provisionOutput =
                    ADLClient.triggerIndexing(libraryId, uploadedFiles);

                result.filesAccepted = provisionOutput == null
                    ? uploadedFiles.size()
                    : provisionOutput.filesAccepted;

                result.status = provisionOutput == null ? 'IN_PROGRESS' : provisionOutput.status;

                result.message = provisionOutput == null
                    ? 'Files were uploaded and indexing was started.'
                    : provisionOutput.message;
            }

            return result;
        } catch (Exception e) {
            throw handled(e);
        }
    }

    // ---------------------------------------------------------------------
    // Mapping helpers
    // ---------------------------------------------------------------------

    private static ADLClient.LibraryOutput mergeLibraryOutputs(
        ADLClient.LibraryOutput summary,
        ADLClient.LibraryOutput detail
    ) {
        if (summary == null) return detail;
        if (detail == null) return summary;

        if (String.isBlank(detail.libraryId)) detail.libraryId = summary.libraryId;
        if (String.isBlank(detail.masterLabel)) detail.masterLabel = summary.masterLabel;
        if (String.isBlank(detail.developerName)) detail.developerName = summary.developerName;
        if (String.isBlank(detail.description)) detail.description = summary.description;
        if (String.isBlank(detail.sourceType)) detail.sourceType = summary.sourceType;
        if (String.isBlank(detail.dataSpaceScopeId)) detail.dataSpaceScopeId = summary.dataSpaceScopeId;

        if (detail.groundingSource == null) {
            detail.groundingSource = summary.groundingSource;
        }

        return detail;
    }

    private static LibraryVM toLibraryVM(ADLClient.LibraryOutput lib) {
        LibraryVM vm = new LibraryVM();
        vm.files = new List<FileVM>();
        vm.stages = new List<StageVM>();

        if (lib == null) {
            vm.status = 'UNKNOWN';
            vm.currentStage = 'NOT_STARTED';
            return vm;
        }

        vm.id = lib.libraryId;
        vm.name = lib.masterLabel;
        vm.devName = lib.developerName;
        vm.description = lib.description;
        vm.sourceType = lib.sourceType;
        vm.dataSpaceScopeId = lib.dataSpaceScopeId;

        if (String.isBlank(vm.sourceType) && lib.groundingSource != null) {
            vm.sourceType = lib.groundingSource.groundingSourceType;
        }

        if (
            lib.groundingSource != null &&
            lib.groundingSource.groundingFileRefs != null
        ) {
            vm.files = toFileVMs(lib.groundingSource.groundingFileRefs);
        }

        return vm;
    }

    private static List<FileVM> toFileVMs(List<ADLClient.GroundingFileRef> refs) {
        List<FileVM> files = new List<FileVM>();

        if (refs == null || refs.isEmpty()) {
            return files;
        }

        Integer fallbackIndex = 0;

        for (ADLClient.GroundingFileRef ref : refs) {
            if (ref == null) continue;

            FileVM f = new FileVM();
            f.fileId = ref.fileId;
            f.fileName = ref.fileName;
            f.filePath = ref.filePath;
            f.fileSize = ref.fileSize == null ? 0 : ref.fileSize.longValue();
            f.groundingSourceId = ref.groundingSourceId;
            f.createdDate = ref.createdDate;
            f.createdBy = String.isBlank(ref.createdBy) ? 'Unknown' : ref.createdBy;
            f.createdById = ref.createdById;

            if (String.isBlank(f.fileName) && String.isNotBlank(f.filePath)) {
                f.fileName = fileNameFromPath(f.filePath);
            }

            if (String.isBlank(f.fileId)) {
                f.fileId = 'file-' + String.valueOf(fallbackIndex) + '-' + String.valueOf(Crypto.getRandomInteger());
            }

            fallbackIndex++;
            files.add(f);
        }

        return files;
    }

    private static String fileNameFromPath(String path) {
        if (String.isBlank(path)) return null;
        List<String> parts = path.split('/');
        return parts.isEmpty() ? path : parts[parts.size() - 1];
    }

    private static void applyStatusSafely(LibraryVM vm) {
        if (vm == null || String.isBlank(vm.id)) return;

        try {
            ADLClient.StatusOutput statusOutput = ADLClient.getStatus(vm.id);
            applyStatus(vm, statusOutput);
        } catch (Exception statusEx) {
            vm.statusFailed = true;
            vm.statusMessage = statusEx.getMessage();

            if (String.isBlank(vm.status)) vm.status = 'UNKNOWN';
            if (String.isBlank(vm.currentStage)) vm.currentStage = 'STATUS_UNAVAILABLE';
            if (vm.stages == null || vm.stages.isEmpty()) vm.stages = defaultStages(null);

            System.debug(
                LoggingLevel.WARN,
                'ADLConsoleController status failed for library ' + vm.id + ': ' + vm.statusMessage
            );
        }
    }

    private static void applyStatus(LibraryVM vm, ADLClient.StatusOutput statusOutput) {
        if (vm == null) return;

        if (statusOutput == null || statusOutput.indexingStatus == null) {
            vm.status = 'NO_STATUS';
            vm.currentStage = 'NOT_STARTED';
            vm.stages = defaultStages(null);
            vm.lastUpdatedAt = DateTime.now().getTime();
            return;
        }

        ADLClient.IndexingStatus indexingStatus = statusOutput.indexingStatus;

        vm.status = String.isBlank(indexingStatus.status) ? 'NO_STATUS' : indexingStatus.status;
        vm.currentStage = String.isBlank(indexingStatus.currentStage) ? 'NOT_STARTED' : indexingStatus.currentStage;
        vm.lastUpdatedAt = indexingStatus.lastUpdatedAt == null ? DateTime.now().getTime() : indexingStatus.lastUpdatedAt;

        vm.stages = new List<StageVM>();

        if (indexingStatus.stageDetails != null) {
            for (ADLClient.StageDetail detail : indexingStatus.stageDetails) {
                if (detail == null) continue;

                StageVM s = new StageVM();
                s.stage = detail.stage;
                s.status = String.isBlank(detail.status) ? 'SCHEDULED' : detail.status;
                s.completedAt = detail.completedAt;
                vm.stages.add(s);
            }
        }

        if (vm.stages.isEmpty()) {
            vm.stages = defaultStages(vm.currentStage);
        }
    }

    private static List<StageVM> defaultStages(String activeStage) {
        List<String> names = new List<String>{
            'DATA_LAKE_OBJECT',
            'DATA_MODEL_OBJECT',
            'SEARCH_INDEX',
            'RETRIEVER'
        };

        List<StageVM> stages = new List<StageVM>();

        for (String name : names) {
            StageVM s = new StageVM();
            s.stage = name;
            s.status = name == activeStage ? 'IN_PROGRESS' : 'SCHEDULED';
            s.completedAt = null;
            stages.add(s);
        }

        return stages;
    }

    private static Boolean hasExistingFiles(String libraryId) {
        try {
            ADLClient.LibraryOutput lib = ADLClient.getLibrary(libraryId);

            return lib != null &&
                lib.groundingSource != null &&
                lib.groundingSource.groundingFileRefs != null &&
                !lib.groundingSource.groundingFileRefs.isEmpty();
        } catch (Exception e) {
            System.debug(
                LoggingLevel.WARN,
                'Could not check existing files for library ' + libraryId + ': ' + e.getMessage()
            );
            return false;
        }
    }

    private static AuraHandledException handled(Exception e) {
        if (e instanceof AuraHandledException) {
            return (AuraHandledException) e;
        }

        String message = e.getMessage();

        if (String.isBlank(message)) {
            message = 'Unexpected Agentforce Data Library error.';
        }

        return new AuraHandledException(message);
    }
}