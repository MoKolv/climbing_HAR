//
//  FilesView.swift
//  arvos
//
//  Browse and manage recorded files - Bento Box Design
//

import SwiftUI
import QuickLook

struct FilesView: View {
    @StateObject private var recordingManager = RecordingManager()
    @State private var recordings: [SessionMetadata] = []
    @State private var showingDeleteAlert = false
    @State private var selectedRecording: SessionMetadata?
    @State private var showingShareSheet = false
    @State private var shareItems: [URL] = []
    @State private var showingDetailView = false
    @State private var isLoading = false
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if recordings.isEmpty {
                    emptyState
                } else {
                    recordingsList
                }
            }
            .navigationTitle("Recordings")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: loadRecordings) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .disabled(isLoading)
                }
            }
            .alert("Delete Recording", isPresented: $showingDeleteAlert) {
                Button("Cancel", role: .cancel) {
                    selectedRecording = nil
                }
                Button("Delete", role: .destructive) {
                    if let recording = selectedRecording {
                        deleteRecording(recording)
                        selectedRecording = nil
                    }
                }
            } message: {
                if let recording = selectedRecording {
                    Text("Are you sure you want to delete \"\(recording.mode.rawValue)\" from \(formatDate(recording.startTime))? This action cannot be undone.")
                } else {
                    Text("Are you sure you want to delete this recording? This action cannot be undone.")
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(items: shareItems)
            }
            .sheet(isPresented: $showingDetailView) {
                if let recording = selectedRecording {
                    RecordingDetailView(
                        recording: recording,
                        onDelete: {
                            showingDetailView = false
                            showingDeleteAlert = true
                        },
                        onShare: {
                            showingDetailView = false
                            shareRecording(recording)
                        }
                    )
                }
            }
            .onAppear {
                loadRecordings()
            }
            .alert("Error", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
            .quickLookPreview($previewURL)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(.secondary)

                VStack(spacing: 4) {
                    Text("No Recordings")
                        .font(.headline)

                    Text("Start streaming to record")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    // MARK: - Recordings List

    private var recordingsList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 12) {
                ForEach(recordings, id: \.sessionId) { recording in
                    RecordingCard(
                        recording: recording,
                        onTap: {
                            selectedRecording = recording
                            showingDetailView = true
                        },
                        onShare: {
                            shareRecording(recording)
                        },
                        onDelete: {
                            selectedRecording = recording
                            showingDeleteAlert = true
                        }
                    )
                }
            }
            .padding(16)
        }
    }

    // MARK: - Actions

    private func loadRecordings() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedRecordings = recordingManager.listRecordings()
            DispatchQueue.main.async {
                recordings = loadedRecordings
                isLoading = false
            }
        }
    }

    private func deleteRecording(_ recording: SessionMetadata) {
        do {
            try recordingManager.deleteRecording(sessionId: recording.sessionId)
            loadRecordings()
        } catch {
            errorMessage = "Failed to delete recording: \(error.localizedDescription)"
            showingErrorAlert = true
        }
    }

    private func shareRecording(_ recording: SessionMetadata) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingsDir = documents.appendingPathComponent(Constants.Recording.recordingsDirectory)
        let sessionDir = recordingsDir.appendingPathComponent(recording.sessionId)

        // Get all files in the session directory
        do {
            let files = try FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil)
            if files.isEmpty {
                errorMessage = "No files found in this recording."
                showingErrorAlert = true
                return
            }
            shareItems = files
            showingShareSheet = true
        } catch {
            errorMessage = "Failed to access files: \(error.localizedDescription)"
            showingErrorAlert = true
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Recording Card (Bento Style)

struct RecordingCard: View {
    let recording: SessionMetadata
    let onTap: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 12) {
                // Header
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: recording.mode.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.primary)

                        Text(recording.mode.rawValue)
                            .font(.system(.caption, weight: .semibold))
                    }

                    Spacer()

                    Text(formatDate(recording.startTime))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Stats Row
                HStack(spacing: 12) {
                    StatPill(icon: "clock", value: formatDuration(recording.duration))
                    StatPill(icon: "doc", value: formatFileSize(recording.fileSize))
                    Spacer()
                }

                // Sensor Icons
                HStack(spacing: 6) {
                    if recording.sensorCounts.cameraFrames > 0 {
                        SensorIcon(icon: "camera.fill")
                    }
                    if recording.sensorCounts.depthFrames > 0 {
                        SensorIcon(icon: "cube.fill")
                    }
                    if recording.sensorCounts.imuSamples > 0 {
                        SensorIcon(icon: "gyroscope")
                    }
                    if recording.sensorCounts.poseSamples > 0 {
                        SensorIcon(icon: "location.fill")
                    }
                    if recording.sensorCounts.gpsSamples > 0 {
                        SensorIcon(icon: "map.fill")
                    }
                    Spacer()

                    // Quick Actions
                    HStack(spacing: 8) {
                        Button(action: onShare) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .font(.system(size: 12))
                                .foregroundColor(Theme.recording)
                        }
                    }
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                    .fill(Color(.systemBackground))
            )
        }
        .buttonStyle(.plain)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb < 1.0 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.0fK", kb)
        }
        return String(format: "%.1fM", mb)
    }
}

struct StatPill: View {
    let icon: String
    let value: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(value)
                .font(.system(size: 10, design: .monospaced))
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}

struct SensorIcon: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
    }
}

// MARK: - Recording Detail View

struct RecordingDetailView: View {
    let recording: SessionMetadata
    let onDelete: () -> Void
    let onShare: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filesList: [FileItem] = []
    @State private var previewURL: URL?
    @State private var showingErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 12) {
                        // Header Card
                        HStack(spacing: 12) {
                            Image(systemName: recording.mode.icon)
                                .font(.system(size: 20))
                                .foregroundColor(.primary)
                                .frame(width: 40, height: 40)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color(.secondarySystemBackground))
                                )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(recording.mode.rawValue)
                                    .font(.system(.subheadline, weight: .semibold))

                                Text(formatDate(recording.startTime))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                                .fill(Color(.systemBackground))
                        )

                        // Stats Grid
                        HStack(spacing: 12) {
                            DetailBentoCard(icon: "clock", label: "Duration", value: formatDuration(recording.duration))
                            DetailBentoCard(icon: "doc", label: "Size", value: formatFileSize(recording.fileSize))
                        }
                        .frame(height: 70)

                        // Sensor Data
                        VStack(spacing: 8) {
                            LazyVGrid(columns: [
                                GridItem(.flexible()),
                                GridItem(.flexible()),
                                GridItem(.flexible())
                            ], spacing: 8) {
                                if recording.sensorCounts.cameraFrames > 0 {
                                    SensorDataCard(icon: "camera.fill", label: "Cam", count: recording.sensorCounts.cameraFrames)
                                }
                                if recording.sensorCounts.depthFrames > 0 {
                                    SensorDataCard(icon: "cube.fill", label: "Depth", count: recording.sensorCounts.depthFrames)
                                }
                                if recording.sensorCounts.imuSamples > 0 {
                                    SensorDataCard(icon: "gyroscope", label: "IMU", count: recording.sensorCounts.imuSamples)
                                }
                                if recording.sensorCounts.poseSamples > 0 {
                                    SensorDataCard(icon: "location.fill", label: "Pose", count: recording.sensorCounts.poseSamples)
                                }
                                if recording.sensorCounts.gpsSamples > 0 {
                                    SensorDataCard(icon: "map.fill", label: "GPS", count: recording.sensorCounts.gpsSamples)
                                }
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                                .fill(Color(.systemBackground))
                        )

                        // Files List
                        if !filesList.isEmpty {
                            VStack(spacing: 6) {
                                ForEach(filesList) { file in
                                    Button {
                                        previewFile(file)
                                    } label: {
                                        HStack {
                                            Image(systemName: file.icon)
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                                .frame(width: 20)

                                            Text(file.name)
                                                .font(.system(size: 11, design: .monospaced))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)

                                            Spacer()

                                            Text(formatFileSize(file.size))
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundColor(.secondary)

                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 9))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color(.secondarySystemBackground))
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color(.systemBackground))
                            )
                        }

                        // Action Buttons
                        HStack(spacing: 10) {
                            Button {
                                onShare()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Share")
                                        .font(.system(.caption, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                                        .fill(Theme.accent)
                                )
                            }

                            Button(role: .destructive) {
                                onDelete()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("Delete")
                                        .font(.system(.caption, weight: .semibold))
                                }
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                                        .fill(Theme.recording)
                                )
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.caption)
                }
            }
            .onAppear {
                loadFiles()
            }
            .quickLookPreview($previewURL)
            .alert("Cannot Preview", isPresented: $showingErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func previewFile(_ file: FileItem) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingsDir = documents.appendingPathComponent(Constants.Recording.recordingsDirectory)
        let fileURL = recordingsDir.appendingPathComponent(recording.sessionId).appendingPathComponent(file.name)

        // Check if the file exists and can be previewed
        if FileManager.default.fileExists(atPath: fileURL.path) {
            previewURL = fileURL
        } else {
            errorMessage = "File not found."
            showingErrorAlert = true
        }
    }

    private func loadFiles() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let recordingsDir = documents.appendingPathComponent(Constants.Recording.recordingsDirectory)
        let sessionDir = recordingsDir.appendingPathComponent(recording.sessionId)

        do {
            let urls = try FileManager.default.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: [.fileSizeKey])
            filesList = urls.compactMap { url in
                guard let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                      let fileSize = resourceValues.fileSize else {
                    return nil
                }

                return FileItem(
                    name: url.lastPathComponent,
                    size: Int64(fileSize),
                    icon: iconForFile(url.lastPathComponent)
                )
            }.sorted { $0.name < $1.name }
        } catch {
        }
    }

    private func iconForFile(_ filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "mcap":
            return "doc.badge.gearshape"
        case "json":
            return "doc.text"
        case "ply":
            return "cube.fill"
        case "h264", "mp4", "mov":
            return "video.fill"
        case "jpg", "jpeg", "png":
            return "photo.fill"
        default:
            return "doc"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatFullDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        if mb < 1.0 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", mb)
    }
}

struct FileItem: Identifiable {
    let id = UUID()
    let name: String
    let size: Int64
    let icon: String
}

struct DetailBentoCard: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Text(value)
                .font(
                    .system(size: 12, weight: .bold, design: .monospaced)
                )
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.largeCornerRadius, style: .continuous)
                .fill(Color(.systemBackground))
        )
    }
}

struct SensorDataCard: View {
    let icon: String
    let label: String
    let count: Int

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Text(formatCount(count))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1000000 {
            return String(format: "%.1fM", Double(count) / 1000000.0)
        } else if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

#Preview {
    FilesView()
}
