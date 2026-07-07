import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct EntryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var entry: JournalEntry
    let isNew: Bool

    @State private var isShowingDateEditor = false
    @State private var isShowingDeleteConfirmation = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var isImportingPhotos = false
    @State private var photoImportAlert: PhotoImportAlert?
    @State private var photoActionAlert: PhotoActionAlert?
    @State private var focusedTextBlockID: UUID?
    @State private var textSelections: [UUID: NSRange] = [:]
    @State private var focusRequest: EditorFocusRequest?
    @State private var transientTextAfterPhotoBlockID: UUID?
    @State private var selectedPhoto: EntryPhoto?
    @State private var photoInfoPromptPhoto: EntryPhoto?

    private let photoStorage = PhotoStorage()
    private static let emptyEntryTextKey = "empty-entry-text"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                entryInfo

                TextField("Title", text: titleBinding, prompt: Text("Title"))
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Title")

                blockEditor

                if isImportingPhotos {
                    Label("Adding Photos...", systemImage: "photo")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .navigationTitle(entry.entryDate.formatted(.dateTime.month(.wide).day().year()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 0,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label("Insert Photos", systemImage: "photo.on.rectangle")
                }
                .disabled(isImportingPhotos)

                Menu {
                    Button(role: .destructive) {
                        isShowingDeleteConfirmation = true
                    } label: {
                        Label("Delete Entry", systemImage: "trash")
                    }
                } label: {
                    Label("Entry Actions", systemImage: "ellipsis.circle")
                }

                Button("Done", action: finish)
            }
        }
        .sheet(isPresented: $isShowingDateEditor) {
            NavigationStack {
                EntryDateEditorView(entry: entry) {
                    _ = saveChange()
                }
            }
        }
        .fullScreenCover(item: $selectedPhoto) { photo in
            PhotoDetailView(
                photo: photo,
                storage: photoStorage,
                useAsEntryInfo: { usePhotoAsEntryInfo(photo) },
                deletePhoto: { deletePhoto(photo) }
            )
        }
        .confirmationDialog(
            "Delete Entry?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Entry", role: .destructive, action: deleteEntry)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This entry will be removed from this device.")
        }
        .confirmationDialog(
            "Use Photo Info?",
            isPresented: isPhotoInfoPromptPresented,
            titleVisibility: .visible,
            presenting: photoInfoPromptPhoto
        ) { photo in
            Button("Use Photo Info") {
                usePhotoAsEntryInfo(photo)
                photoInfoPromptPhoto = nil
            }
            Button("Keep Entry Info") {
                entry.hasShownPhotoInfoPrompt = true
                saveChange()
                photoInfoPromptPhoto = nil
            }
            Button("Cancel", role: .cancel) {
                photoInfoPromptPhoto = nil
            }
        } message: { _ in
            Text("The first photo has date or place information that differs from this entry.")
        }
        .alert(item: $photoImportAlert) { alert in
            Alert(
                title: Text("Some Photos Couldn’t Be Added"),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(item: $photoActionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: selectedPhotoItems) { _, newItems in
            importPhotoItems(newItems)
        }
    }

    private var entryInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                isShowingDateEditor = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .accessibilityHidden(true)
                    Text(entryDateText)
                    if entry.isAllDay {
                        Text("All-day")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Entry Date")
            .accessibilityValue(entry.isAllDay ? "\(entryDateText), \(String(localized: "All-day"))" : entryDateText)

            if let locationText = entry.locationDisplayText {
                Label {
                    Text(locationText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Location")
                .accessibilityValue(locationText)
            }
        }
    }

    private var blockEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if entry.orderedBlocks.isEmpty {
                textEditor(
                    text: transientTextBinding(after: nil),
                    blockID: nil,
                    focusKey: Self.emptyEntryTextKey,
                    placeholder: "Write something..."
                )
            }

            ForEach(entry.orderedBlocks) { block in
                switch block.kind {
                case .text:
                    textEditor(
                        text: textBinding(for: block),
                        blockID: block.id,
                        focusKey: Self.textFocusKey(for: block.id),
                        placeholder: "Write something..."
                    )
                case .photoGroup:
                    PhotoGroupBlockView(block: block, storage: photoStorage) { photo in
                        selectedPhoto = photo
                    }

                    if transientTextAfterPhotoBlockID == block.id {
                        textEditor(
                            text: transientTextBinding(after: block),
                            blockID: nil,
                            focusKey: Self.transientTextFocusKey(after: block.id),
                            placeholder: "Write something..."
                        )
                    }
                }
            }
        }
    }

    private var entryDateText: String {
        if entry.isAllDay {
            return entry.entryDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        }
        return entry.entryDate.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute())
    }

    private var isPhotoInfoPromptPresented: Binding<Bool> {
        Binding(
            get: { photoInfoPromptPhoto != nil },
            set: { isPresented in
                if !isPresented {
                    photoInfoPromptPhoto = nil
                }
            }
        )
    }

    private var titleBinding: Binding<String> {
        Binding(
            get: { entry.title },
            set: { newValue in
                entry.title = newValue
                saveChange()
            }
        )
    }

    private func textBinding(for block: EntryBlock) -> Binding<String> {
        Binding(
            get: { block.text },
            set: { newValue in
                block.text = newValue
                saveChange()
            }
        )
    }

    private func transientTextBinding(after previousBlock: EntryBlock?) -> Binding<String> {
        Binding(
            get: { "" },
            set: { newValue in
                guard let block = entry.insertTextBlock(newValue, after: previousBlock, in: modelContext) else { return }
                transientTextAfterPhotoBlockID = nil
                saveChange()
                focusRequest = EditorFocusRequest(key: Self.textFocusKey(for: block.id), offset: newValue.count)
            }
        )
    }

    private func textEditor(
        text: Binding<String>,
        blockID: UUID?,
        focusKey: String,
        placeholder: LocalizedStringKey
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }

            CursorTextView(
                text: text,
                blockID: blockID,
                focusKey: focusKey,
                focusedTextBlockID: $focusedTextBlockID,
                textSelections: $textSelections,
                focusRequest: $focusRequest
            )
        }
        .accessibilityLabel("Body")
    }

    private func importPhotoItems(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        selectedPhotoItems = []

        let targetBlockID = focusedTextBlockID
        let targetCursorOffset = cursorOffset(for: targetBlockID)

        Task { @MainActor in
            isImportingPhotos = true
            let result = await PhotoPickerImporter(storage: photoStorage).importItems(items)
            isImportingPhotos = false

            if let insertion = entry.insertPhotoGroup(
                photos: result.photos,
                focusedTextBlockID: targetBlockID,
                cursorOffset: targetCursorOffset,
                in: modelContext
            ) {
                let promptPhoto = entry.photoInfoPromptCandidate(from: insertion.photoBlock.orderedPhotos)

                if saveChange() {
                    focusAfterPhotoInsertion(insertion)
                    photoInfoPromptPhoto = promptPhoto
                } else {
                    modelContext.rollback()
                    if deleteStoredFiles(result.fileNames) {
                        photoActionAlert = PhotoActionAlert(
                            title: String(localized: "Some Photos Couldn’t Be Added"),
                            message: String(localized: "Some selected photos could not be added.")
                        )
                    } else {
                        photoActionAlert = PhotoActionAlert(
                            title: String(localized: "Photo File Couldn’t Be Deleted"),
                            message: String(localized: "Some copied photo files could not be deleted.")
                        )
                    }
                }
            }

            photoImportAlert = result.alert
        }
    }

    private func focusAfterPhotoInsertion(_ insertion: PhotoGroupInsertion) {
        if let followingTextBlock = insertion.followingTextBlock {
            transientTextAfterPhotoBlockID = nil
            focusRequest = EditorFocusRequest(key: Self.textFocusKey(for: followingTextBlock.id), offset: 0)
        } else {
            transientTextAfterPhotoBlockID = insertion.photoBlock.id
            focusRequest = EditorFocusRequest(key: Self.transientTextFocusKey(after: insertion.photoBlock.id), offset: 0)
        }
    }

    private func cursorOffset(for blockID: UUID?) -> Int? {
        guard let blockID,
              let block = entry.orderedBlocks.first(where: { $0.id == blockID }) else { return nil }
        let range = textSelections[blockID] ?? NSRange(location: block.text.utf16.count, length: 0)
        return characterOffset(fromUTF16Offset: range.location, in: block.text)
    }

    private func characterOffset(fromUTF16Offset offset: Int, in text: String) -> Int {
        let clampedOffset = min(max(offset, 0), text.utf16.count)
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: clampedOffset)
        guard let index = String.Index(utf16Index, within: text) else { return text.count }
        return text.distance(from: text.startIndex, to: index)
    }

    private static func textFocusKey(for blockID: UUID) -> String {
        blockID.uuidString
    }

    private static func transientTextFocusKey(after blockID: UUID) -> String {
        "after-\(blockID.uuidString)"
    }

    @discardableResult
    private func saveChange() -> Bool {
        entry.normalizeBlocks(in: modelContext)
        entry.updatedAt = .now
        do {
            try modelContext.save()
            return true
        } catch {
            return false
        }
    }

    private func finish() {
        entry.normalizeBlocks(in: modelContext)
        if isNew {
            _ = discardBlankNewEntry(entry, in: modelContext)
        }
        try? modelContext.save()
        dismiss()
    }

    private func usePhotoAsEntryInfo(_ photo: EntryPhoto) {
        entry.applyInfo(from: photo)
        entry.hasShownPhotoInfoPrompt = true
        saveChange()
    }

    private func deletePhoto(_ photo: EntryPhoto) {
        let blockID = photo.block?.id
        let fileName = entry.deletePhoto(photo, in: modelContext)
        if let blockID, !entry.orderedBlocks.contains(where: { $0.id == blockID }) {
            transientTextAfterPhotoBlockID = nil
        }
        selectedPhoto = nil

        guard saveChange() else {
            modelContext.rollback()
            photoActionAlert = PhotoActionAlert(
                title: String(localized: "Photo Couldn’t Be Deleted"),
                message: String(localized: "Try deleting the photo again.")
            )
            return
        }

        do {
            try photoStorage.delete(fileName: fileName)
        } catch {
            photoActionAlert = PhotoActionAlert(
                title: String(localized: "Photo File Couldn’t Be Deleted"),
                message: String(localized: "The photo was removed from this entry, but its copied file could not be deleted.")
            )
        }
    }

    private func deleteStoredFiles(_ fileNames: [String]) -> Bool {
        fileNames.reduce(true) { succeeded, fileName in
            do {
                try photoStorage.delete(fileName: fileName)
                return succeeded
            } catch {
                return false
            }
        }
    }

    private func deleteEntry() {
        modelContext.delete(entry)
        try? modelContext.save()
        dismiss()
    }
}

private struct PhotoActionAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct EditorFocusRequest: Equatable {
    let key: String
    let offset: Int
}

struct PhotoGroupBlockView: View {
    let block: EntryBlock
    let storage: PhotoStorage
    let openPhoto: (EntryPhoto) -> Void

    var body: some View {
        let photos = block.orderedPhotos

        Group {
            if let photo = photos.first, photos.count == 1 {
                Button {
                    openPhoto(photo)
                } label: {
                    StoredPhotoThumbnail(photo: photo, storage: storage, cornerRadius: 10, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Photo")
            } else {
                let layout = photoGroupLayoutPlan(forPhotoCount: photos.count)
                let columnCount = photoGroupColumnCount(forPhotoCount: photos.count)
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columnCount),
                    spacing: 4
                ) {
                    ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                        let cellLayout = layout[index]
                        Button {
                            openPhoto(photo)
                        } label: {
                            Color.clear
                                .aspectRatio(cellLayout.aspectRatio, contentMode: .fit)
                                .overlay {
                                    StoredPhotoThumbnail(photo: photo, storage: storage, cornerRadius: 10)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open Photo")
                        .gridCellColumns(cellLayout.columnSpan)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo Group")
    }
}

private struct PhotoDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: EntryPhoto
    let storage: PhotoStorage
    let useAsEntryInfo: () -> Void
    let deletePhoto: () -> Void
    @State private var isShowingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                photoContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()

                metadataBar
            }
            .navigationTitle("Photo Detail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        if photo.hasUsableEntryInfo {
                            Button {
                                useAsEntryInfo()
                            } label: {
                                Label("Use as Entry Info", systemImage: "calendar.badge.clock")
                            }
                        }

                        Button(role: .destructive) {
                            isShowingDeleteConfirmation = true
                        } label: {
                            Label("Delete Photo", systemImage: "trash")
                        }
                    } label: {
                        Label("Photo Actions", systemImage: "ellipsis.circle")
                    }

                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                "Delete Photo?",
                isPresented: $isShowingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Photo", role: .destructive) {
                    deletePhoto()
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This photo will be removed from this entry.")
            }
        }
    }

    @ViewBuilder
    private var photoContent: some View {
        if let image = storage.image(for: photo.fileName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Photo")
        } else {
            VStack(spacing: 12) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                Text("Photo unavailable")
            }
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    @ViewBuilder
    private var metadataBar: some View {
        if photo.hasVisibleMetadata {
            VStack(alignment: .leading, spacing: 8) {
                if let capturedAt = photo.capturedAt {
                    Label {
                        Text(capturedAt.formatted(.dateTime.weekday(.abbreviated).month().day().year().hour().minute()))
                    } icon: {
                        Image(systemName: "calendar")
                    }
                    .accessibilityLabel("Captured")
                    .accessibilityValue(capturedAt.formatted(.dateTime.weekday(.wide).month(.wide).day().year().hour().minute()))
                }

                if let placeText = photo.placeDisplayText {
                    Label {
                        Text(placeText)
                    } icon: {
                        Image(systemName: "mappin.and.ellipse")
                    }
                    .accessibilityLabel("Location")
                    .accessibilityValue(placeText)
                }
            }
            .font(.footnote)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding()
            .accessibilityElement(children: .contain)
        }
    }
}

private struct CursorTextView: UIViewRepresentable {
    @Binding var text: String
    let blockID: UUID?
    let focusKey: String
    @Binding var focusedTextBlockID: UUID?
    @Binding var textSelections: [UUID: NSRange]
    @Binding var focusRequest: EditorFocusRequest?

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.textContainer.lineFragmentPadding = 0
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self
        if textView.text != text {
            textView.text = text
        }

        guard let request = focusRequest, request.key == focusKey else { return }
        if !textView.isFirstResponder {
            textView.becomeFirstResponder()
        }
        textView.selectedRange = NSRange(location: utf16Offset(forCharacterOffset: request.offset, in: textView.text), length: 0)
        DispatchQueue.main.async {
            if focusRequest == request {
                focusRequest = nil
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? UIScreen.main.bounds.width
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(48, size.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func utf16Offset(forCharacterOffset offset: Int, in text: String) -> Int {
        let characterOffset = min(max(offset, 0), text.count)
        let index = text.index(text.startIndex, offsetBy: characterOffset)
        return index.samePosition(in: text.utf16).map { text.utf16.distance(from: text.utf16.startIndex, to: $0) } ?? text.utf16.count
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CursorTextView

        init(parent: CursorTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.focusedTextBlockID = parent.blockID
            saveSelection(textView)
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            saveSelection(textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            saveSelection(textView)
        }

        private func saveSelection(_ textView: UITextView) {
            guard let blockID = parent.blockID else { return }
            parent.textSelections[blockID] = textView.selectedRange
        }
    }
}

private struct EntryDateEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var entry: JournalEntry
    let saveChange: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle("All-day", isOn: allDayBinding)

                DatePicker(
                    "Date",
                    selection: entryDateBinding,
                    displayedComponents: entry.isAllDay ? .date : [.date, .hourAndMinute]
                )
                .id(entry.isAllDay)
            }
        }
        .navigationTitle("Entry Date")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }

    private var allDayBinding: Binding<Bool> {
        Binding(
            get: { entry.isAllDay },
            set: { newValue in
                entry.setAllDay(newValue)
                saveChange()
            }
        )
    }

    private var entryDateBinding: Binding<Date> {
        Binding(
            get: { entry.entryDate },
            set: { newValue in
                entry.setEntryDate(newValue)
                saveChange()
            }
        )
    }
}
