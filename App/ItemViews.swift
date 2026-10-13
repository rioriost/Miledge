import MiledgeApplication
import MiledgeDomain
import SwiftUI
import UniformTypeIdentifiers

struct EditorFieldViewIdentity: Hashable {
    let field: EditorFieldID
    let generation: UUID?
}

/// Unknown saved records stay protected; an unfinished edit is a validation error, not a loss of editing access.
struct EditorInitialAccess {
    let readOnly: Bool
    init(revision: VaultRevision) { readOnly = revision.isReadOnly || revision.deleted }
}

/// Draft-only input buffers belong to custom fields even when their surrounding item type changes.
enum EditorTypeChangeState {
    static func preserves(_ field: VaultField, in section: VaultSection) -> Bool {
        section.id == "custom" || UUID(uuidString: section.id) != nil || UUID(uuidString: field.id) != nil
    }

    static func identity(for field: VaultField, in section: VaultSection, generation: UUID) -> EditorFieldViewIdentity {
        EditorFieldViewIdentity(
            field: EditorFieldID(section: section.id, field: field.id),
            generation: preserves(field, in: section) ? nil : generation
        )
    }

    static func retainedInvalidFields(_ invalid: Set<EditorFieldID>, in revision: VaultRevision) -> Set<EditorFieldID> {
        let retained = Set(revision.sections.flatMap { section in
            section.fields.filter { preserves($0, in: section) }.map {
                EditorFieldID(section: section.id, field: $0.id)
            }
        })
        return invalid.intersection(retained)
    }
}

struct TemplatePickerChoice: Hashable {
    let templateID: String
    let profileID: String?
}

struct ItemTypePicker: View {
    @Binding var selection: TemplatePickerChoice
    @Environment(\.locale) private var locale

    static var choices: [TemplatePickerChoice] {
        TemplateCatalog.all.flatMap { template in
            [TemplatePickerChoice(templateID: template.id, profileID: nil)]
                + (template.id == "affiliate-account" ? TemplateCatalog.affiliateProfiles.map {
                    TemplatePickerChoice(templateID: template.id, profileID: $0.id)
                } : [])
        }
    }

    static func choice(for revision: VaultRevision) -> TemplatePickerChoice {
        let profile = revision.templateId == "affiliate-account"
            ? revision.sections.flatMap(\.fields).first { $0.id == "profileId" }?.value : nil
        if case .string(let id) = profile, !id.isEmpty {
            return TemplatePickerChoice(templateID: revision.templateId, profileID: id)
        }
        return TemplatePickerChoice(templateID: revision.templateId, profileID: nil)
    }

    static func name(for choice: TemplatePickerChoice, locale: Locale) -> String {
        guard let template = TemplateCatalog.template(id: choice.templateID) else {
            return CatalogLocalization.string("Unsupported field", locale: locale)
        }
        let name = CatalogLocalization.templateName(template, locale: locale)
        guard let id = choice.profileID, let profile = TemplateCatalog.affiliateProfile(id: id) else { return name }
        return name + " — " + CatalogLocalization.affiliateName(profile, locale: locale)
    }

    var body: some View {
        Picker("Item type", selection: $selection) {
            ForEach(Self.choices, id: \.self) { choice in
                Text(verbatim: Self.name(for: choice, locale: locale)).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("item-type-picker")
        .accessibilityValue(Text(verbatim: Self.name(for: selection, locale: locale)))
    }
}

struct TemplatePicker: View {
    var category = LedgerCategory.all
    var embedded = false
    let select: (ItemTemplate, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: TemplatePickerChoice?
    @Environment(\.locale) private var locale

    private var templates: [ItemTemplate] {
        category.templates.filter { CatalogLocalization.matches($0, query: query, locale: locale) }
    }

    static func choices(category: LedgerCategory, query: String, locale: Locale) -> [TemplatePickerChoice] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return category.templates.filter { CatalogLocalization.matches($0, query: query, locale: locale) }.flatMap { template in
            if template.id == "affiliate-account" {
                return TemplateCatalog.affiliateProfiles.filter {
                    query.isEmpty || CatalogLocalization.templateName(template, locale: locale).range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
                        || template.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: locale) != nil
                        || CatalogLocalization.matches($0, query: query, locale: locale)
                }.map { TemplatePickerChoice(templateID: template.id, profileID: $0.id) }
            }
            return [TemplatePickerChoice(templateID: template.id, profileID: nil)]
        }
    }

    static func resolve(_ choice: TemplatePickerChoice?, in visible: [TemplatePickerChoice]) -> (ItemTemplate, String?)? {
        guard let choice, visible.contains(choice), let template = TemplateCatalog.template(id: choice.templateID) else { return nil }
        return (template, choice.profileID)
    }

    private var visibleChoices: [TemplatePickerChoice] { Self.choices(category: category, query: query, locale: locale) }

    var body: some View {
        Group {
            if embedded { content }
            else { NavigationStack { content } }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 400)
        #endif
        .presentationSizing(.form)
    }

    private var content: some View {
        pickerList
            .accessibilityIdentifier("template-picker-list")
            .overlay {
                if visibleChoices.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle("Item type")
            .searchable(text: $query)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("template-picker-cancel")
                }
            }
            .onChange(of: visibleChoices) { _, choices in
                if let selection, !choices.contains(selection) { self.selection = nil }
            }
    }

    @ViewBuilder
    private var pickerList: some View {
        #if os(macOS)
        List(selection: $selection) { rows }
            .onKeyPress(.return, phases: .down) { _ in
                activate(selection) ? .handled : .ignored
            }
            .contextMenu(forSelectionType: TemplatePickerChoice.self) { _ in
                EmptyView()
            } primaryAction: { choices in
                guard choices.count == 1 else { return }
                _ = activate(choices.first)
            }
        #else
        List { rows }
        #endif
    }

    @ViewBuilder
    private var rows: some View {
        ForEach(templates) { template in
            if template.id == "affiliate-account" {
                Section(CatalogLocalization.templateName(template, locale: locale)) {
                    ForEach(TemplateCatalog.affiliateProfiles.filter {
                        visibleChoices.contains(TemplatePickerChoice(templateID: template.id, profileID: $0.id))
                    }, id: \.id) { profile in
                        choiceRow(TemplatePickerChoice(templateID: template.id, profileID: profile.id)) {
                            Text(verbatim: CatalogLocalization.affiliateName(profile, locale: locale))
                        }
                    }
                }
            } else {
                choiceRow(TemplatePickerChoice(templateID: template.id, profileID: nil)) {
                    Label { Text(verbatim: CatalogLocalization.templateName(template, locale: locale)) } icon: {
                        Image(systemName: LedgerCategory.group(for: template.id).symbol)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func choiceRow<Content: View>(_ choice: TemplatePickerChoice, @ViewBuilder label: () -> Content) -> some View {
        #if os(macOS)
        label()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .tag(choice)
            .accessibilityIdentifier("template-\(choice.profileID ?? choice.templateID)")
            .accessibilityAction { _ = activate(choice) }
        #else
        Button { _ = activate(choice) } label: {
            label().frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("template-\(choice.profileID ?? choice.templateID)")
        #endif
    }

    @discardableResult
    private func activate(_ choice: TemplatePickerChoice?) -> Bool {
        guard let (template, profile) = Self.resolve(choice, in: visibleChoices) else { return false }
        select(template, profile)
        return true
    }
}

struct ItemCreationView: View {
    let category: LedgerCategory
    let session: VaultSession
    var attachments: AttachmentService?
    var copy: ((JSONValue) -> Bool)?
    let saved: (VaultRevision) -> Void
    @State private var draft: VaultRevision?
    @State private var issue: String?

    var body: some View {
        Group {
            if let draft {
                ItemEditor(revision: draft, attachments: attachments, relatedItems: session.visibleItems(),
                           creating: true, copy: copy, changeType: { revision, template, profile in
                    let replacement = try session.newDraft(template: template, affiliateProfileId: profile)
                    return try VaultEditor.replacingTypeFields(in: revision, with: replacement)
                }) { revision in
                    do {
                        try session.save(revision)
                        saved(revision)
                    } catch {
                        issue = String(localized: "The item could not be saved. Your changes are still open.")
                    }
                }
            } else {
                TemplatePicker(category: category) { template, profile in
                    do {
                        draft = try session.newDraft(template: template, affiliateProfileId: profile)
                    } catch {
                        issue = String(localized: "Unlock the ledger before adding items.")
                    }
                }
            }
        }
        .alert("Unable to complete the action", isPresented: Binding(
            get: { issue != nil }, set: { if !$0 { issue = nil } }
        )) {
            Button("OK") { issue = nil }
        } message: {
            Text(issue ?? "")
        }
    }
}

struct ItemOrganizationInput: View {
    @Binding var tags: [String]
    @Binding var favorite: Bool
    @State private var draft: StringListFieldDraft
    @State var expanded = false

    init(tags: Binding<[String]>, favorite: Binding<Bool>, expanded: Bool = false) {
        _tags = tags
        _favorite = favorite
        _draft = State(initialValue: StringListFieldDraft(strings: tags.wrappedValue))
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup("Organization", isExpanded: $expanded) {
            Toggle("Favorite", isOn: $favorite)
            StringListDraftInput(draft: $draft, valueLabel: "Tag", addLabel: "Add tag", removeLabel: "Remove tag")
        }
        .autocorrectionDisabled()
        .buttonStyle(.borderless)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .onChange(of: draft) { _, draft in tags = draft.strings }
    }
}

struct RelatedItemLabel: View {
    let recordId: UUID
    let resolution: RelatedItemResolution

    var body: some View {
        switch resolution {
        case .available(let revision):
            Text(verbatim: revision.title)
                .accessibilityValue(recordId.uuidString)
        case .conflicted, .unavailable:
            VStack(alignment: .leading) {
                Text(LocalizedStringKey(resolution == .conflicted ? "Conflicting changes" : "Item unavailable"))
                Text(verbatim: recordId.uuidString).ledgerFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct RelatedItemPicker: View {
    let items: [VaultRevision]
    let excluded: Set<UUID>
    let select: (VaultRevision) -> Void
    @Environment(\.dismiss) private var dismiss
    @State var query = ""

    private var choices: [VaultRevision] {
        items.filter { item in
            guard !excluded.contains(item.recordId),
                  case .available = RelatedItemResolution.resolve(recordId: item.recordId, heads: items) else {
                return false
            }
            return query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
                || item.recordId.uuidString.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
            List(choices) { item in
                Button { select(item) } label: {
                    RelatedItemLabel(recordId: item.recordId, resolution: .available(item))
                }
                .accessibilityIdentifier("related-choice-\(item.recordId.uuidString)")
            }
            .overlay {
                if choices.isEmpty {
                    if query.isEmpty { ContentUnavailableView("No items available", systemImage: "link") }
                    else { ContentUnavailableView.search(text: query) }
                }
            }
            .navigationTitle("Add related item")
            .searchable(text: $query)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                        .accessibilityIdentifier("related-picker-cancel")
                }
            }
    }
}

struct ItemRelatedItemsInput: View {
    @Binding var recordIds: [UUID]
    let recordId: UUID
    let items: [VaultRevision]
    var chooseItem: (() -> Void)?
    @State private var draft: RelatedItemsDraft
    @State var expanded = false

    init(recordIds: Binding<[UUID]>, recordId: UUID, items: [VaultRevision], expanded: Bool = false, chooseItem: (() -> Void)? = nil) {
        _recordIds = recordIds
        self.recordId = recordId
        self.items = items
        self.chooseItem = chooseItem
        _draft = State(initialValue: RelatedItemsDraft(recordIds: recordIds.wrappedValue))
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        DisclosureGroup("Related items", isExpanded: $expanded) {
            ForEach(draft.entries) { entry in
                VStack(alignment: .leading) {
                    RelatedItemLabel(
                        recordId: entry.recordId,
                        resolution: RelatedItemResolution.resolve(recordId: entry.recordId, heads: items)
                    )
                    Button("Remove related item", role: .destructive) {
                        draft.entries.removeAll { $0.id == entry.id }
                    }
                    .accessibilityValue(entry.recordId.uuidString)
                }
            }
            Button("Add related item", systemImage: "link.badge.plus") { chooseItem?() }
                .accessibilityIdentifier("add-related-item")
        }
        .buttonStyle(.borderless)
        .onChange(of: draft) { _, draft in recordIds = draft.recordIds }
        .onChange(of: recordIds) { _, values in
            if values != draft.recordIds { draft = RelatedItemsDraft(recordIds: values) }
        }
    }
}

struct ItemDetailView: View {
    let revision: VaultRevision
    let conflicted: Bool
    let edit: () -> Void
    let delete: () -> Void
    var relatedItems: [VaultRevision] = []
    var openRelated: ((UUID) -> Void)?
    var copy: ((JSONValue) -> Bool)?
    var resolveConflict: (() -> Void)?
    var reviewingVersion = false
    @Environment(\.concealValuesByDefault) private var concealByDefault
    var attachments: AttachmentService?
    @State private var confirmingDelete = false

    var body: some View {
        Form {
            Section {
                Text(revision.title).ledgerFont(.title2)
                Text(LocalizedStringKey(revision.storageScope == .deviceLocal
                    ? "On this device only" : "Synchronization enabled"))
                    .ledgerFont(.caption)
                    .foregroundStyle(.secondary)
                if conflicted { Label("Conflicting changes", systemImage: "exclamationmark.triangle") }
                if revision.deleted { Text("Deletion revision") }
                if revision.isReadOnly {
                    Label("This item is read-only or no longer available.", systemImage: "lock")
                }
            }
            if revision.favorite || !revision.tags.isEmpty {
                Section("Organization") {
                    if revision.favorite { Label("Favorite", systemImage: "star.fill") }
                    ForEach(Array(revision.tags.enumerated()), id: \.offset) { _, tag in
                        Text(verbatim: tag)
                    }
                }
            }
            if !revision.linkedRecordIds.isEmpty {
                Section("Related items") {
                    ForEach(Array(revision.linkedRecordIds.enumerated()), id: \.offset) { _, recordId in
                        let resolution = RelatedItemResolution.resolve(recordId: recordId, heads: relatedItems)
                        if reviewingVersion {
                            Text(verbatim: recordId.uuidString)
                                .environment(\.layoutDirection, .leftToRight)
                        } else if case .available(let target) = resolution, let openRelated {
                            Button { openRelated(target.revisionId) } label: {
                                RelatedItemLabel(recordId: recordId, resolution: resolution)
                            }
                            .accessibilityIdentifier("related-open-\(recordId.uuidString)")
                        } else {
                            RelatedItemLabel(recordId: recordId, resolution: resolution)
                        }
                    }
                }
            }
            ForEach(revision.sections, id: \.id) { section in
                Section {
                    ForEach(section.fields.filter { FieldValueView.hasContent($0) }) { field in
                        FieldDetailRow(field: field, copy: copy)
                            .environment(\.concealValuesByDefault, reviewingVersion || concealByDefault)
                    }
                }
            }
            if !revision.attachments.isEmpty {
                Section("Files") {
                    ForEach(Array(revision.attachments.enumerated()), id: \.offset) { _, attachment in
                        AttachmentRow(attachment: attachment, service: attachments)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("item-detail-form")
        .toolbar {
            if !reviewingVersion {
                if conflicted, let resolveConflict {
                    ToolbarItem {
                        Button("Resolve conflict", systemImage: "arrow.triangle.merge", action: resolveConflict)
                    }
                }
                ToolbarItem {
                    Button("Edit", action: edit).disabled(conflicted || revision.deleted || revision.isReadOnly)
                }
                ToolbarItem {
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                        .disabled(conflicted || revision.deleted || revision.isReadOnly)
                }
            }
        }
        .confirmationDialog("Delete this item? Revision history will remain.", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive, action: delete)
        }
        .onChange(of: revision.revisionId) { _, _ in confirmingDelete = false }
        .id(revision.revisionId)
    }
}

struct ItemEditor: View {
    @State var revision: VaultRevision
    var attachments: AttachmentService?
    var relatedItems: [VaultRevision] = []
    var creating = false
    var copy: ((JSONValue) -> Bool)?
    var changeType: ((VaultRevision, ItemTemplate, String?) throws -> VaultRevision)?
    let save: (VaultRevision) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var importingFile = false
    @State private var editorIssue: String?
    @State private var invalidFields = Set<EditorFieldID>()
    @State private var pendingFieldRemoval: EditorFieldID?
    @State private var pendingSectionRemoval: String?
    @State private var choosingRelatedItem = false
    @State private var pendingType: ItemTemplate?
    @State private var pendingProfile: String?
    @State private var fieldGeneration = UUID()
    @State private var initialAccess: EditorInitialAccess
    @State private var defaultTitle = EditorDefaultTitle()
    private let initialFields: Set<EditorFieldID>
    @Environment(\.displayTextSize) private var displayTextSize
    @Environment(\.locale) private var locale
    @Environment(\.timeZone) private var timeZone

    init(
        revision: VaultRevision, attachments: AttachmentService? = nil,
        relatedItems: [VaultRevision] = [], creating: Bool = false,
        copy: ((JSONValue) -> Bool)? = nil,
        changeType: ((VaultRevision, ItemTemplate, String?) throws -> VaultRevision)? = nil,
        save: @escaping (VaultRevision) -> Void
    ) {
        _revision = State(initialValue: revision)
        _initialAccess = State(initialValue: EditorInitialAccess(revision: revision))
        self.attachments = attachments
        self.relatedItems = relatedItems
        self.creating = creating
        self.copy = copy
        initialFields = creating ? [] : Set(revision.sections.flatMap { section in
            section.fields.filter { FieldValueView.hasContent($0) }.map { EditorFieldID(section: section.id, field: $0.id) }
        })
        self.changeType = changeType
        self.save = save
    }

    private var readOnly: Bool { initialAccess.readOnly }

    private func customSection(_ section: VaultSection) -> Bool {
        section.id == "custom" || UUID(uuidString: section.id) != nil
    }

    private var validationMessage: String? {
        do {
            try VaultEditor.validateDraft(revision)
            return nil
        } catch {
            return String(localized: "Check the fields before saving.")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Basic information") {
                    if let template = TemplateCatalog.template(id: revision.templateId) {
                        if changeType != nil {
                            ItemTypePicker(selection: typeSelection)
                        } else {
                            LabeledContent("Item type") { Text(verbatim: CatalogLocalization.templateName(template, locale: locale)) }
                                .accessibilityElement(children: .ignore)
                                .accessibilityAddTraits(.isStaticText)
                                .accessibilityLabel("Item type")
                                .accessibilityValue(Text(verbatim: CatalogLocalization.templateName(template, locale: locale)))
                                .accessibilityIdentifier("item-type-display")
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title").ledgerFont(.subheadline)
                        HStack {
                            #if os(macOS)
                            MacFieldInput(text: titleBinding, label: String(localized: "Title", locale: locale),
                                          placeholder: String(localized: "Title", locale: locale))
                            #else
                            TextField("", text: titleBinding, prompt: Text("Title"))
                                .fieldControlFrame()
                                .accessibilityLabel("Title")
                                .frame(maxWidth: .infinity, alignment: .leading)
                            #endif
                        }
                        .multilineTextAlignment(.leading)
                    }
                    if readOnly {
                        Label("This item is read-only or no longer available.", systemImage: "lock")
                    } else if let validationMessage {
                        Text(validationMessage).ledgerFont(.caption).foregroundStyle(.red)
                    }
                }
                ForEach(Array(revision.sections.enumerated()).filter {
                    !customSection($0.element) && !$0.element.fields.isEmpty
                }, id: \.element.id) { sectionIndex, section in
                    Section(EditorSectionName.name(for: section.id)) {
                        fields(in: section, at: sectionIndex)
                        if VaultEditor.canRemoveSection(in: revision, sectionID: section.id) {
                            removeSectionButton(section.id)
                        }
                    }
                }
                Section("Additional fields") {
                    ForEach(Array(revision.sections.enumerated()).filter {
                        customSection($0.element)
                    }, id: \.element.id) { sectionIndex, section in
                        fields(in: section, at: sectionIndex)
                    }
                    Menu("Add field", systemImage: "plus") {
                        ForEach(VaultEditor.supportedKinds, id: \.self) { kind in
                            Button(FieldKindName.name(for: kind)) { addField(kind: kind) }
                        }
                    }
                    Menu("Template fields", systemImage: "list.bullet") {
                        switch Result(catching: { try VaultEditor.availableSections(for: revision) }) {
                        case .success(let options):
                            ForEach(options, id: \.id) { option in
                                Button(EditorSectionName.name(for: option.section.id)) {
                                    do {
                                        revision = try VaultEditor.addingSection(id: option.id, to: revision)
                                    } catch {
                                        editorIssue = String(localized: "The fields could not be added.")
                                    }
                                }
                            }
                            if options.isEmpty {
                                Text("All template fields are present.")
                            }
                        case .failure:
                            Button("The fields could not be added.") {
                                editorIssue = String(localized: "Check the fields before saving.")
                            }
                        }
                    }
                }
                if !revision.attachments.isEmpty || (attachments != nil && revision.storageScope == .deviceLocal) {
                    Section("Files") {
                        ForEach(Array(revision.attachments.enumerated()), id: \.offset) { _, attachment in
                            AttachmentRow(attachment: attachment, service: attachments) {
                                if let index = revision.attachments.firstIndex(of: attachment) {
                                    revision.attachments.remove(at: index)
                                }
                            }
                        }
                        if attachments != nil, revision.storageScope == .deviceLocal {
                            Button("Attach file", systemImage: "paperclip") { importingFile = true }
                        }
                    }
                }
                Section {
                    ItemOrganizationInput(tags: $revision.tags, favorite: $revision.favorite)
                    ItemRelatedItemsInput(
                        recordIds: $revision.linkedRecordIds, recordId: revision.recordId, items: relatedItems,
                        chooseItem: { choosingRelatedItem = true }
                    )
                }
            }
            .formStyle(.grouped)
            .navigationDestination(isPresented: $choosingRelatedItem) {
                RelatedItemPicker(items: relatedItems, excluded: Set(revision.linkedRecordIds + [revision.recordId])) { item in
                    revision.linkedRecordIds.append(item.recordId)
                    choosingRelatedItem = false
                }
            }
            #if os(macOS)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            #endif
            .accessibilityIdentifier("item-editor-form")
            .disabled(readOnly)
            .navigationTitle(creating ? "New item" : "Edit item")
            .toolbar {
                if !choosingRelatedItem {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save(revision) }
                            .keyboardShortcut(.defaultAction)
                            .disabled(readOnly || validationMessage != nil || !invalidFields.isEmpty
                                || revision.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            if !readOnly {
                defaultTitle.initialize(revision: &revision, creating: creating, locale: locale, timeZone: timeZone)
            }
        }
        .alert("Change this item type?", isPresented: Binding(
            get: { pendingType != nil }, set: { if !$0 { pendingType = nil; pendingProfile = nil } }
        )) {
            if let template = pendingType {
                let profile = pendingProfile
                Button("Change type", role: .destructive) { replaceType(template: template, profile: profile) }
                    .accessibilityIdentifier("confirm-change-type")
            }
            Button("Cancel", role: .cancel) { pendingType = nil; pendingProfile = nil }
                .accessibilityIdentifier("cancel-change-type")
        } message: {
            Text("Existing type fields and their values will be removed. Your title edits, organization, related items, and files are kept.")
        }
        .confirmationDialog("Remove this field?", isPresented: Binding(
            get: { pendingFieldRemoval != nil }, set: { if !$0 { pendingFieldRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeField() }
                .accessibilityIdentifier("confirm-remove-field")
        } message: { Text("Other fields and saved history remain.") }
        .confirmationDialog("Remove this section?", isPresented: Binding(
            get: { pendingSectionRemoval != nil }, set: { if !$0 { pendingSectionRemoval = nil } }
        ), titleVisibility: .visible) {
            Button("Remove section", role: .destructive) { removeSection() }
                .accessibilityIdentifier("confirm-remove-section")
        } message: { Text("Other fields and saved history remain.") }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data]) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                guard let attachments else { throw AttachmentError.invalidFile }
                let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType?.identifier
                    ?? UTType.data.identifier
                let metadata = try attachments.importFile(url, mediaType: type, scope: revision.storageScope)
                revision.attachments.append(metadata.json)
            } catch AttachmentError.tooLarge {
                editorIssue = String(localized: "Files must be 20 MiB or smaller.")
            } catch {
                editorIssue = String(localized: "The file could not be encrypted and attached. Try again.")
            }
        }
        .alert("Unable to complete the action", isPresented: Binding(
            get: { editorIssue != nil }, set: { if !$0 { editorIssue = nil } }
        )) {
            Button("OK") { editorIssue = nil }
        } message: {
            Text(editorIssue ?? "")
        }
        #if os(macOS)
        .frame(minWidth: 560, idealWidth: max(560, 680 * displayTextSize.scale),
               minHeight: 520, idealHeight: max(520, 680 * displayTextSize.scale))
        #endif
        .presentationSizing(.form)
        .resizeForDisplayText()
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    private func fields(in section: VaultSection, at sectionIndex: Int) -> some View {
        ForEach(Array(section.fields.enumerated()), id: \.element.id) { fieldIndex, field in
            EditableField(
                field: fieldBinding(sectionID: section.id, fieldID: field.id, fallback: field),
                invalid: invalidBinding(section: section.id, field: field.id),
                templateID: revision.templateId,
                initiallyVisible: !initialFields.contains(EditorFieldID(section: section.id, field: field.id)),
                copy: copy.map { copy in { value in
                    let success = copy(value)
                    if !success { editorIssue = String(localized: "The value could not be copied. Try again.") }
                    return success
                } },
                onRemove: VaultEditor.canRemoveField(in: revision, sectionID: section.id, fieldID: field.id)
                    ? { pendingFieldRemoval = EditorFieldID(section: section.id, field: field.id) } : nil
            )
            .id(EditorTypeChangeState.identity(for: field, in: section, generation: fieldGeneration))
        }
    }

    private func fieldBinding(sectionID: String, fieldID: String, fallback: VaultField) -> Binding<VaultField> {
        Binding {
            revision.sections.first { $0.id == sectionID }?.fields.first { $0.id == fieldID } ?? fallback
        } set: { value in
            guard let section = revision.sections.firstIndex(where: { $0.id == sectionID }),
                  let field = revision.sections[section].fields.firstIndex(where: { $0.id == fieldID }) else { return }
            revision.sections[section].fields[field] = value
        }
    }

    private func removeSectionButton(_ id: String) -> some View {
        Button("Remove section", systemImage: "minus.circle", role: .destructive) { pendingSectionRemoval = id }
            .accessibilityIdentifier("remove-section-\(id)")
    }

    private func removeField() {
        guard let target = pendingFieldRemoval else { return }
        do {
            revision = try VaultEditor.removingField(in: revision, sectionID: target.section, fieldID: target.field)
            invalidFields.remove(target)
        } catch { editorIssue = String(localized: "Check the fields before saving.") }
        pendingFieldRemoval = nil
    }

    private func removeSection() {
        guard let id = pendingSectionRemoval else { return }
        do {
            revision = try VaultEditor.removingSection(in: revision, sectionID: id)
            invalidFields = invalidFields.filter { $0.section != id }
        } catch { editorIssue = String(localized: "Check the fields before saving.") }
        pendingSectionRemoval = nil
    }

    private func replaceType(template: ItemTemplate, profile: String?) {
        guard let changeType else { return }
        do {
            revision = try changeType(revision, template, profile)
            defaultTitle.updateType(revision: &revision, locale: locale)
            invalidFields = EditorTypeChangeState.retainedInvalidFields(invalidFields, in: revision)
            fieldGeneration = UUID()
        } catch { editorIssue = String(localized: "The fields could not be added.") }
        pendingType = nil
        pendingProfile = nil
    }

    private var typeSelection: Binding<TemplatePickerChoice> {
        Binding {
            if let pendingType {
                return TemplatePickerChoice(templateID: pendingType.id, profileID: pendingProfile)
            }

            return ItemTypePicker.choice(for: revision)
        } set: { choice in
            guard choice != ItemTypePicker.choice(for: revision) else { return }
            guard let template = TemplateCatalog.template(id: choice.templateID),
                  ItemTypePicker.choices.contains(choice) else {
                editorIssue = String(localized: "The fields could not be added.")
                return
            }
            pendingType = template
            pendingProfile = choice.profileID
        }
    }

    private var titleBinding: Binding<String> {
        Binding(get: { revision.title }, set: { defaultTitle.edit($0, revision: &revision) })
    }

    private func invalidBinding(section: String, field: String) -> Binding<Bool> {
        let id = EditorFieldID(section: section, field: field)
        return Binding(
            get: { invalidFields.contains(id) },
            set: { invalid in
                if invalid { invalidFields.insert(id) }
                else { invalidFields.remove(id) }
            }
        )
    }

    private func addField(kind: String) {
        do {
            let field = try VaultEditor.customField(kind: kind, label: "")
            revision.sections.append(VaultSection(id: UUID().uuidString, fields: [field]))
        } catch {
            editorIssue = String(localized: "The fields could not be added.")
        }
    }
}
