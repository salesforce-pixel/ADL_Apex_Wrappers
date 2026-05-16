import { LightningElement, track } from 'lwc';
import getLibraries from '@salesforce/apex/ADLConsoleController.getLibraries';
import createLibrary from '@salesforce/apex/ADLConsoleController.createLibrary';
import uploadFiles from '@salesforce/apex/ADLConsoleController.uploadFiles';
import deleteLibrary from '@salesforce/apex/ADLConsoleController.deleteLibrary';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const FILE_LIMIT_PER_LIBRARY = 1000;
const MAX_FILES_PER_BATCH = 20;
const MAX_FILE_SIZE_BYTES = 4_000_000;

const STAGE_DESCRIPTIONS = {
    DATA_LAKE_OBJECT: 'File ingested into Data Cloud lake',
    DATA_MODEL_OBJECT: 'Mapped to DMO for query access',
    SEARCH_INDEX: 'Content chunked and embedded',
    RETRIEVER: 'Retriever provisioned over index',
    NOT_STARTED: 'Waiting for first indexing request',
    STATUS_UNAVAILABLE: 'Status endpoint could not be read'
};

const TERMINAL_STATUSES = ['READY', 'FAILED', 'INCOMPLETE', 'NO_SOURCES', 'NO_STATUS', 'UNKNOWN'];

export default class AgentforceDataLibraries extends LightningElement {
    @track libraries = [];
    @track pendingFiles = [];

    activeView = 'home';
    selectedLibraryId;
    isBusy = false;
    isUploading = false;
    isDragging = false;
    errorMessage;

    librarySearch = '';
    statusFilter = '';
    fileSearch = '';
    fileLibraryFilter = '';
    fileTypeFilter = '';

    showCreateModal = false;
    createMasterLabel = '';
    createDeveloperName = '';
    createDescription = '';

    showDeleteModal = false;
    deleteConfirmInput = '';
    isDeleting = false;

    poller;

    connectedCallback() {
        this.refreshData();
        this.poller = window.setInterval(() => {
            if (this.shouldPoll) {
                this.refreshData({ silent: true });
            }
        }, 30000);
    }

    disconnectedCallback() {
        if (this.poller) window.clearInterval(this.poller);
    }

    // ---------- View state ----------

    get isHomeView() { return this.activeView === 'home'; }
    get isLibrariesView() { return this.activeView === 'libraries'; }
    get isFilesView() { return this.activeView === 'files'; }
    get isDetailView() { return this.activeView === 'detail'; }

    get homeTabClass() { return this.activeView === 'home' ? 'active' : ''; }
    get librariesTabClass() {
        return this.activeView === 'libraries' || this.activeView === 'detail' ? 'active' : '';
    }
    get filesTabClass() { return this.activeView === 'files' ? 'active' : ''; }

    get shouldPoll() {
        return this.librariesVm.some((lib) => !TERMINAL_STATUSES.includes(lib.status));
    }

    handleViewChange(event) {
        this.activeView = event.currentTarget.dataset.view;
        window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    selectLibrary(event) {
        const id = event.currentTarget.dataset.id;
        if (!id) return;
        this.selectedLibraryId = id;
        this.pendingFiles = [];
        this.activeView = 'detail';
        window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    // ---------- Data ----------

    async refreshData(options = {}) {
        const silent = options.silent === true;
        if (!silent) {
            this.isBusy = true;
            this.errorMessage = undefined;
        }

        try {
            const data = await getLibraries();
            const normalized = this.normalizeLibraries(Array.isArray(data) ? data : []);
            this.libraries = normalized;

            if (this.selectedLibraryId &&
                !this.libraries.some((lib) => lib.id === this.selectedLibraryId)) {
                this.selectedLibraryId = undefined;
            }

            if (!this.selectedLibraryId && this.libraries.length) {
                this.selectedLibraryId = this.libraries[0].id;
            }
        } catch (error) {
            this.errorMessage = this.normalizeError(error);
            if (!silent) this.toast('Could not load libraries', this.errorMessage, 'error');
        } finally {
            if (!silent) this.isBusy = false;
        }
    }

    normalizeLibraries(libraries) {
        return libraries
            .filter((lib) => lib && lib.id)
            .map((lib) => ({
                ...lib,
                name: lib.name || lib.masterLabel || 'Untitled library',
                devName: lib.devName || lib.developerName || '',
                description: lib.description || '',
                sourceType: lib.sourceType || 'SFDRIVE',
                status: lib.status || 'NO_STATUS',
                currentStage: lib.currentStage || 'NOT_STARTED',
                lastUpdatedAt: lib.lastUpdatedAt || Date.now(),
                files: this.normalizeFiles(lib.files || []),
                stages: this.normalizeStageList(lib.stages || [])
            }));
    }

    normalizeFiles(files) {
        return files
            .filter((file) => file)
            .map((file, index) => ({
                ...file,
                fileId: file.fileId || file.id || `${file.filePath || file.fileName || 'file'}-${index}`,
                fileName: file.fileName || this.fileNameFromPath(file.filePath) || 'Untitled file',
                filePath: file.filePath || '',
                fileSize: Number(file.fileSize ?? file.size ?? 0),
                createdDate: file.createdDate || file.createdAt || '',
                createdBy: file.createdBy || file.createdByName || 'Unknown',
                createdById: file.createdById || ''
            }));
    }

    normalizeStageList(stages) {
        return stages
            .filter((stage) => stage)
            .map((stage) => ({
                stage: stage.stage || 'UNKNOWN',
                status: stage.status || 'SCHEDULED',
                completedAt: stage.completedAt || null
            }));
    }

    clearError() { this.errorMessage = undefined; }

    // ---------- Create library ----------

    openCreateModal() {
        this.showCreateModal = true;
        this.errorMessage = undefined;
    }

    closeCreateModal() { this.showCreateModal = false; }

    handleBackdropClick(event) {
        if (event.target.classList.contains('modal-backdrop')) {
            this.closeCreateModal();
        }
    }

    handleCreateMasterLabel(event) {
        this.createMasterLabel = event.target.value;
        this.createDeveloperName = this.toDeveloperName(this.createMasterLabel);
    }

    handleCreateDeveloperName(event) {
        this.createDeveloperName = event.target.value;
    }

    handleCreateDescription(event) {
        this.createDescription = event.target.value;
    }

    async submitCreateLibrary() {
        const masterLabel = (this.createMasterLabel || '').trim();
        const developerName = (this.createDeveloperName || '').trim();
        const description = (this.createDescription || '').trim();

        if (!masterLabel || !developerName) {
            this.toast('Missing fields', 'Master label and developer name are required.', 'warning');
            return;
        }

        if (!/^[a-zA-Z][a-zA-Z0-9_]*$/.test(developerName)) {
            this.toast('Invalid developer name',
                'Developer name must start with a letter and contain only letters, numbers, and underscores.',
                'warning');
            return;
        }

        this.isBusy = true;
        try {
            // Send as JSON string — bypasses the LWC → Apex inner-class binding
            // bug that was causing "MasterLabel is required" failures even when
            // the form was filled in correctly. Same workaround as uploadFiles.
            const created = await createLibrary({
                requestJson: JSON.stringify({ masterLabel, developerName, description })
            });

            this.createMasterLabel = '';
            this.createDeveloperName = '';
            this.createDescription = '';
            this.showCreateModal = false;

            await this.refreshData({ silent: true });

            this.selectedLibraryId = created?.id || this.selectedLibraryId;
            this.activeView = 'detail';
            this.toast('Library created', `${masterLabel} is ready for files.`, 'success');
        } catch (error) {
            this.toast('Create failed', this.normalizeError(error), 'error');
        } finally {
            this.isBusy = false;
        }
    }

    // ---------- Delete library ----------

    openDeleteModal() {
        if (!this.selectedLibraryId) return;
        this.deleteConfirmInput = '';
        this.showDeleteModal = true;
    }

    closeDeleteModal() {
        if (this.isDeleting) return;
        this.showDeleteModal = false;
        this.deleteConfirmInput = '';
    }

    handleDeleteBackdropClick(event) {
        if (event.target.classList.contains('modal-backdrop')) {
            this.closeDeleteModal();
        }
    }

    handleDeleteConfirmInput(event) {
        this.deleteConfirmInput = event.target.value;
    }

    get deleteConfirmMatches() {
        const label = this.selectedLibrary?.name || '';
        return Boolean(label) && this.deleteConfirmInput === label;
    }

    get deleteConfirmDisabled() {
        return !this.deleteConfirmMatches || this.isDeleting;
    }

    async confirmDeleteLibrary() {
        if (!this.deleteConfirmMatches || !this.selectedLibraryId) return;

        const idToDelete = this.selectedLibraryId;
        const labelToDelete = this.selectedLibrary?.name || idToDelete;

        this.isDeleting = true;
        this.isBusy = true;

        try {
            await deleteLibrary({ libraryId: idToDelete });

            this.showDeleteModal = false;
            this.deleteConfirmInput = '';
            this.selectedLibraryId = undefined;
            this.pendingFiles = [];

            await this.refreshData({ silent: true });
            this.activeView = 'libraries';
            this.toast('Library deleted', `${labelToDelete} was deleted.`, 'success');
        } catch (error) {
            this.toast('Delete failed', this.normalizeError(error), 'error');
        } finally {
            this.isDeleting = false;
            this.isBusy = false;
        }
    }

    // ---------- Upload ----------

    get dropzoneClass() {
        return this.isDragging ? 'dropzone dragging' : 'dropzone';
    }

    get pendingFileSummary() {
        const count = this.pendingFiles.length;
        return count === 1 ? '1 file selected' : `${count} files selected`;
    }

    get pendingSizeSummary() {
        return this.formatSize(this.pendingFiles.reduce((sum, file) => sum + Number(file.size || 0), 0));
    }

    handleDragOver(event) {
        event.preventDefault();
        this.isDragging = true;
    }

    handleDragLeave() { this.isDragging = false; }

    handleDrop(event) {
        event.preventDefault();
        this.isDragging = false;
        const files = Array.from(event?.dataTransfer?.files || []);
        this.addPendingFiles(files);
    }

    handleFilePicker(event) {
        const files = this.extractFilesFromEvent(event);
        this.addPendingFiles(files);
        if (event?.target) {
            try { event.target.value = ''; } catch (e) {}
        }
    }

    extractFilesFromEvent(event) {
        const targetFiles = Array.from(event?.target?.files || []);
        if (targetFiles.length) return targetFiles;
        const currentTargetFiles = Array.from(event?.currentTarget?.files || []);
        if (currentTargetFiles.length) return currentTargetFiles;
        const detailFiles = Array.from(event?.detail?.files || []);
        if (detailFiles.length) return detailFiles;
        return [];
    }

    addPendingFiles(files) {
        const accepted = [];
        const rejected = [];
        const existingNames = new Set(this.pendingFiles.map((file) => file.name));

        for (const file of files || []) {
            if (!file || typeof file !== 'object') {
                rejected.push('Skipped an invalid file entry.');
                continue;
            }

            const isBlobLike =
                (typeof Blob !== 'undefined' && file instanceof Blob) ||
                typeof file.arrayBuffer === 'function';

            if (!isBlobLike) {
                rejected.push(`${file.name || 'Unnamed file'}: not a readable file object (try drag-and-drop)`);
                continue;
            }

            if (!file.name || !String(file.name).trim()) {
                rejected.push('Skipped a file with no name.');
                continue;
            }

            const ext = this.extension(file.name);
            if (!['pdf', 'docx', 'doc', 'txt'].includes(ext)) {
                rejected.push(`${file.name}: unsupported type`);
                continue;
            }

            if (!file.size || file.size <= 0) {
                rejected.push(`${file.name}: empty file`);
                continue;
            }

            if (file.size > MAX_FILE_SIZE_BYTES) {
                rejected.push(`${file.name}: larger than ${this.formatSize(MAX_FILE_SIZE_BYTES)}`);
                continue;
            }

            if (existingNames.has(file.name)) {
                rejected.push(`${file.name}: already selected`);
                continue;
            }

            accepted.push(file);
            existingNames.add(file.name);
        }

        if (!accepted.length && !rejected.length) {
            this.toast('No file selected', 'Choose a PDF, DOCX, DOC, or TXT file to upload.', 'warning');
            return;
        }

        const combined = [...this.pendingFiles, ...accepted];
        if (combined.length > MAX_FILES_PER_BATCH) {
            this.toast('Too many files', `Upload at most ${MAX_FILES_PER_BATCH} files at once.`, 'warning');
            this.pendingFiles = combined.slice(0, MAX_FILES_PER_BATCH);
        } else {
            this.pendingFiles = combined;
        }

        if (rejected.length) {
            this.toast('Some files were skipped', rejected.join('\n'), 'warning');
        }
    }

    clearPendingFiles() { this.pendingFiles = []; }

    async uploadPendingFiles() {
        if (!this.selectedLibraryId) {
            this.toast('No library selected', 'Select a library before uploading files.', 'warning');
            return;
        }
        if (!this.pendingFiles.length) {
            this.toast('No files selected', 'Choose a file before clicking Upload & index.', 'warning');
            return;
        }

        this.isUploading = true;
        this.isBusy = true;

        try {
            const payload = [];
            for (const file of this.pendingFiles) {
                const fileName = file?.name ? String(file.name).trim() : '';
                if (!fileName) throw new Error('A selected file is missing its name.');
                const base64Data = await this.fileToBase64(file);
                if (!base64Data) throw new Error(`Could not read file body for ${fileName}.`);
                payload.push({ fileName, base64Data });
            }

            if (!payload.length) throw new Error('No uploadable files were prepared.');

            const result = await uploadFiles({
                libraryId: this.selectedLibraryId,
                filesJson: JSON.stringify(payload)
            });

            this.pendingFiles = [];
            await this.refreshData({ silent: true });
            this.toast('Files submitted',
                result?.message || 'Files were uploaded and submitted for indexing.',
                'success');
        } catch (error) {
            this.toast('Upload failed', this.normalizeError(error), 'error');
        } finally {
            this.isUploading = false;
            this.isBusy = false;
        }
    }

    scrollToUpload() {
        const panel = this.template.querySelector('[data-id="uploadPanel"]');
        if (panel) panel.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }

    fileToBase64(file) {
        return new Promise((resolve, reject) => {
            if (!file) { reject(new Error('No file was provided.')); return; }
            const reader = new FileReader();
            reader.onload = () => {
                try {
                    const value = String(reader.result || '');
                    const commaIndex = value.indexOf(',');
                    const base64 = commaIndex >= 0 ? value.substring(commaIndex + 1) : value;
                    if (!base64 || !base64.trim()) {
                        reject(new Error(`Could not extract base64 content for ${file.name}.`));
                        return;
                    }
                    resolve(base64);
                } catch (error) {
                    reject(error);
                }
            };
            reader.onerror = () => reject(reader.error || new Error(`Could not read ${file.name}.`));
            reader.readAsDataURL(file);
        });
    }

    // ---------- Filters ----------

    handleLibrarySearch(event) { this.librarySearch = event.target.value; }
    handleStatusFilter(event) { this.statusFilter = event.target.value; }
    handleFileSearch(event) { this.fileSearch = event.target.value; }
    handleFileLibraryFilter(event) { this.fileLibraryFilter = event.target.value; }
    handleFileTypeFilter(event) { this.fileTypeFilter = event.target.value; }

    // ---------- View models ----------

    get librariesVm() {
        return this.libraries.map((lib, index) => this.decorateLibrary(lib, index));
    }

    get homeLibraries() { return this.librariesVm.slice(0, 6); }
    get hasLibraries() { return this.libraries.length > 0; }

    get selectedLibrary() {
        return (
            this.librariesVm.find((lib) => lib.id === this.selectedLibraryId) ||
            this.librariesVm[0] ||
            this.emptyLibraryVm
        );
    }

    get filteredLibraries() {
        const q = (this.librarySearch || '').toLowerCase();
        const status = this.statusFilter;
        return this.librariesVm.filter((lib) => {
            if (status && lib.status !== status) return false;
            if (!q) return true;
            return [lib.name, lib.devName, lib.id, lib.descriptionDisplay]
                .filter(Boolean)
                .some((value) => String(value).toLowerCase().includes(q));
        });
    }

    get allFilesVm() {
        const counts = this.fileNameCounts;
        return this.librariesVm.flatMap((lib) =>
            lib.filesVm.map((file) => {
                const duplicateCount = counts[file.fileNameKey] || 0;
                return {
                    ...file,
                    libraryId: lib.id,
                    libraryName: lib.name,
                    libraryPillClass: lib.tonePillClass,
                    duplicateLabel: duplicateCount > 1 ? `in ${duplicateCount} libs` : ''
                };
            })
        );
    }

    get filteredFiles() {
        const q = (this.fileSearch || '').toLowerCase();
        const libraryId = this.fileLibraryFilter;
        const type = this.fileTypeFilter;
        return this.allFilesVm.filter((file) => {
            if (libraryId && file.libraryId !== libraryId) return false;
            if (type && file.ext !== type) return false;
            if (!q) return true;
            return [file.fileName, file.libraryName, file.createdByDisplay]
                .filter(Boolean)
                .some((value) => String(value).toLowerCase().includes(q));
        });
    }

    get fileNameCounts() {
        return this.allRawFiles.reduce((acc, file) => {
            const key = this.fileNameKey(file.fileName);
            if (!key) return acc;
            acc[key] = (acc[key] || 0) + 1;
            return acc;
        }, {});
    }

    get allRawFiles() {
        return this.libraries.flatMap((lib) =>
            (lib.files || []).map((file) => ({
                ...file,
                libraryId: lib.id,
                libraryName: lib.name
            }))
        );
    }

    get duplicateFileNameCount() {
        return Object.values(this.fileNameCounts).filter((count) => count > 1).length;
    }

    get metricLibraries() { return this.libraries.length; }
    get metricFiles() { return this.allRawFiles.length; }

    get metricStorage() {
        return this.formatSize(this.allRawFiles.reduce((sum, file) => sum + Number(file.fileSize || 0), 0));
    }

    get metricQuota() {
        return `${this.metricFiles} / ${this.metricLibraries * FILE_LIMIT_PER_LIBRARY}`;
    }

    get metricLibrarySub() {
        const ready = this.librariesVm.filter((lib) => lib.status === 'READY').length;
        const indexing = this.librariesVm.filter((lib) => !TERMINAL_STATUSES.includes(lib.status)).length;
        return `${ready} ready · ${indexing} indexing`;
    }

    get metricAverageSize() {
        if (!this.metricFiles) return 'No files yet';
        const total = this.allRawFiles.reduce((sum, file) => sum + Number(file.fileSize || 0), 0);
        return `avg ${this.formatSize(total / this.metricFiles)} per file`;
    }

    get largestFile() {
        if (!this.allRawFiles.length) return null;
        return this.allRawFiles.reduce((largest, file) =>
            Number(file.fileSize || 0) > Number(largest.fileSize || 0) ? file : largest
        );
    }

    get largestFileName() { return this.largestFile?.fileName || '—'; }
    get largestFileSize() { return this.largestFile ? this.formatSize(this.largestFile.fileSize) : '—'; }

    get homeSubtitle() { return `${this.metricLibraries} libraries · ${this.metricFiles} files indexed`; }
    get librariesSubtitle() { return `All ${this.metricLibraries} SFDRIVE libraries in your org`; }
    get filesSubtitle() { return `${this.metricFiles} files across ${this.metricLibraries} libraries`; }

    get timeGreeting() {
        const hour = new Date().getHours();
        if (hour < 12) return 'morning';
        if (hour < 18) return 'afternoon';
        return 'evening';
    }

    get userFirstName() { return 'Rajeev'; }

    get emptyLibraryVm() {
        return {
            id: '', name: 'No library selected', devName: '', descriptionDisplay: '',
            sourceType: 'SFDRIVE', status: 'NO_STATUS', currentStage: 'NOT_STARTED',
            currentStageDisplay: '—', statusLabel: 'No status', statusPillClass: 'pill neutral',
            statusDotClass: 'status-dot pending', fileCount: 0, filesVm: [], stagesVm: [],
            totalSizeLabel: '0 B', quotaStyle: 'width:0%', largestFileLabel: 'No files',
            updatedLabel: 'never'
        };
    }

    decorateLibrary(lib, index) {
        const files = Array.isArray(lib.files) ? lib.files : [];
        const stages = Array.isArray(lib.stages) ? lib.stages : [];
        const totalSize = files.reduce((sum, file) => sum + Number(file.fileSize || 0), 0);
        const status = lib.status || 'NO_STATUS';
        const currentStage = lib.currentStage || 'NOT_STARTED';
        const palette = ['purple', 'teal', 'coral', 'pink', 'amber', 'slate'][index % 6];

        const largest = files.length
            ? files.reduce((max, file) => Number(file.fileSize || 0) > Number(max.fileSize || 0) ? file : max)
            : null;

        return {
            ...lib, status, currentStage,
            descriptionDisplay: lib.description || 'No description',
            fileCount: files.length,
            totalSize,
            totalSizeLabel: this.formatSize(totalSize),
            quotaLabel: `${files.length} of ${FILE_LIMIT_PER_LIBRARY} files`,
            quotaStyle: `width:${Math.min(100, (files.length / FILE_LIMIT_PER_LIBRARY) * 100)}%`,
            updatedLabel: this.formatRelativeTime(lib.lastUpdatedAt),
            statusLabel: this.statusLabel(status, currentStage),
            statusPillClass: `pill ${this.statusTone(status)}`,
            tonePillClass: `pill ${palette}`,
            statusDotClass: `status-dot ${this.statusDot(status)}`,
            currentStageDisplay: this.prettyStage(currentStage),
            largestFileLabel: largest ? `largest: ${largest.fileName}` : 'No files',
            filesVm: files.map((file, fileIndex) => this.decorateFile(file, fileIndex)),
            stagesVm: this.normalizeStages(stages, currentStage, status)
        };
    }

    decorateFile(file, index) {
        const fileName = file.fileName || this.fileNameFromPath(file.filePath) || 'Untitled file';
        const ext = this.extension(fileName);
        return {
            ...file,
            key: `${file.fileId || file.filePath || fileName}-${index}`,
            fileName,
            fileNameKey: this.fileNameKey(fileName),
            ext,
            extLabel: ext ? ext.toUpperCase() : 'FILE',
            iconClass: `file-ext ${ext || 'generic'}`,
            sizeLabel: this.formatSize(file.fileSize),
            dateLabel: this.formatDate(file.createdDate),
            createdByDisplay: file.createdBy || 'Unknown'
        };
    }

    normalizeStages(stages, currentStage, overallStatus) {
        const order = ['DATA_LAKE_OBJECT', 'DATA_MODEL_OBJECT', 'SEARCH_INDEX', 'RETRIEVER'];
        const byName = new Map((stages || []).map((stage) => [stage.stage, stage]));
        return order.map((stageName) => {
            const stage = byName.get(stageName) || {
                stage: stageName,
                status: this.defaultStageStatus(stageName, currentStage, overallStatus),
                completedAt: null
            };
            return {
                key: stageName,
                label: this.prettyStage(stageName),
                description: STAGE_DESCRIPTIONS[stageName] || '',
                status: stage.status,
                dotClass: `status-dot ${this.stageDot(stage.status)}`,
                timeLabel: this.stageTimeLabel(stage)
            };
        });
    }

    defaultStageStatus(stageName, currentStage, overallStatus) {
        if (overallStatus === 'READY') return 'SUCCESS';
        if (overallStatus === 'FAILED' && stageName === currentStage) return 'FAILED';
        if (stageName === currentStage) return 'IN_PROGRESS';
        return 'SCHEDULED';
    }

    // ---------- Formatting ----------

    statusLabel(status, currentStage) {
        if (status === 'READY') return 'Ready';
        if (status === 'FAILED') return 'Failed';
        if (status === 'INCOMPLETE') return 'Incomplete';
        if (status === 'NO_SOURCES') return 'No sources';
        if (status === 'NO_STATUS') return 'No status';
        if (status === 'UNKNOWN') return 'Unknown';
        if (currentStage) return this.prettyStage(currentStage);
        return status || 'Unknown';
    }

    statusTone(status) {
        if (status === 'READY') return 'success';
        if (status === 'FAILED' || status === 'INCOMPLETE') return 'danger';
        if (status === 'NO_STATUS' || status === 'UNKNOWN' || status === 'NO_SOURCES') return 'neutral';
        return 'info';
    }

    statusDot(status) {
        if (status === 'READY') return 'success';
        if (status === 'FAILED' || status === 'INCOMPLETE') return 'danger';
        if (status === 'NO_STATUS' || status === 'UNKNOWN' || status === 'NO_SOURCES') return 'pending';
        return 'active';
    }

    stageDot(status) {
        if (status === 'SUCCESS') return 'success';
        if (status === 'FAILED') return 'danger';
        if (status === 'IN_PROGRESS') return 'active';
        return 'pending';
    }

    stageTimeLabel(stage) {
        if (stage.completedAt) {
            return new Date(Number(stage.completedAt)).toLocaleTimeString([], {
                hour: '2-digit', minute: '2-digit'
            });
        }
        if (stage.status === 'IN_PROGRESS') return 'running…';
        if (stage.status === 'FAILED') return 'failed';
        if (stage.status === 'SUCCESS') return 'complete';
        return 'scheduled';
    }

    prettyStage(value) {
        if (!value) return '—';
        return String(value).replaceAll('_', ' ').toLowerCase().replace(/\b\w/g, (char) => char.toUpperCase());
    }

    formatSize(bytes) {
        const value = Number(bytes || 0);
        if (value < 1024) return `${value} B`;
        if (value < 1024 * 1024) return `${(value / 1024).toFixed(0)} KB`;
        if (value < 1024 * 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
        return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GB`;
    }

    formatDate(value) {
        if (!value) return '—';
        const date = new Date(value);
        if (Number.isNaN(date.getTime())) return '—';
        return date.toLocaleDateString([], { month: 'short', day: 'numeric' });
    }

    formatRelativeTime(value) {
        if (!value) return 'never';
        const numericValue = Number(value);
        if (!Number.isFinite(numericValue)) return 'never';
        const diff = Date.now() - numericValue;
        if (diff < 0) return 'just now';
        const min = Math.floor(diff / 60000);
        const hour = Math.floor(min / 60);
        const day = Math.floor(hour / 24);
        if (day > 0) return `${day}d ago`;
        if (hour > 0) return `${hour}h ago`;
        if (min > 0) return `${min}m ago`;
        return 'just now';
    }

    extension(name = '') {
        const parts = String(name).toLowerCase().split('.');
        return parts.length > 1 ? parts.pop() : '';
    }

    fileNameFromPath(path = '') {
        if (!path) return '';
        const parts = String(path).split('/');
        return parts[parts.length - 1] || '';
    }

    fileNameKey(name = '') {
        return String(name || '').trim().toLowerCase();
    }

    toDeveloperName(label = '') {
        return label.replace(/[^a-zA-Z0-9_]/g, '_').replace(/_+/g, '_').replace(/^[^a-zA-Z]+/, '').slice(0, 80);
    }

    normalizeError(error) {
        return (
            error?.body?.message ||
            error?.body?.pageErrors?.[0]?.message ||
            error?.message ||
            'Something went wrong.'
        );
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}