import MiledgeApplication
import MiledgeDomain
import MiledgeStorage
import Observation
import SwiftUI
import XCTest
@testable import MiledgeApp

#if os(macOS)
import AppKit
import ScreenCaptureKit
#else
import UIKit
#endif

@MainActor
final class AppRenderingTests: XCTestCase {
    private func render<Content: View>(
        _ content: Content, named name: String = "Synthetic view", appearance: ColorScheme? = nil,
        exercise: (() async throws -> Void)? = nil
    ) async throws {
        #if os(macOS)
        let controller = NSHostingController(
            rootView: content.frame(width: 900, height: 650).background(.background)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        if let appearance { window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) }
        controller.view.frame = window.contentLayoutRect
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        try await exercise?()
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(controller.view.fittingSize.height, 0)
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let image = NSImage(size: controller.view.bounds.size)
        image.addRepresentation(bitmap)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        #else
        let host = UIHostingController(rootView: content.background(.background))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = appearance == .dark ? .dark : appearance == .light ? .light : .unspecified
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKey()
        }
        host.loadViewIfNeeded()
        host.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(200))
        try await exercise?()
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.view.bounds.width, 300)
        XCTAssertGreaterThan(host.view.bounds.height, 400)
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        #endif
    }

    func testLockedAndEmptyLedgerRender() async throws {
        let session = VaultSession(authenticate: {}, load: { [] }, append: { _, _, _ in })
        try await render(LedgerView(session: session))
        try await session.unlock()
        try await render(LedgerView(session: session))
    }

    func testNativeSelectionAndCalendarPanelsRenderWithoutWritingValues() async throws {
        for locale in ["ja", "ar"] {
            for size in [DisplayTextSize.standard, .largest] {
                let language = Locale(identifier: locale)
                let country = InputFixture(field: VaultField(
                    id: "issuingCountry", kind: "string", value: .string(""), concealed: false
                ))
                let day = InputFixture(field: VaultField(kind: "date", value: .string("2032-02-29"), concealed: false))
                var committed: [String] = []
                try await render(ScrollView { VStack(alignment: .leading) {
                    StringFieldInput(field: country.binding, invalid: country.validation, text: "")
                    StringFieldInput(field: day.binding, invalid: day.validation, text: "2032-02-29")
                    CalendarSelectionPanel(text: "2032-02-29", kind: "date", label: "Synthetic date",
                                           commit: { committed.append($0) }, cancel: {})
                    CalendarSelectionPanel(text: "2031-09", kind: "year-month", label: "Synthetic month",
                                           commit: { committed.append($0) }, cancel: {})
                } }.controlSize(.large).ledgerFont(.body).environment(\.locale, language).environment(\.displayTextSize, size)
                    .environment(\.layoutDirection, locale == "ar" ? .rightToLeft : .leftToRight),
                    named: "Synthetic selectors \(locale) \(size.rawValue)")
                XCTAssertTrue(committed.isEmpty)
                XCTAssertEqual(country.field.value, .string(""))
                XCTAssertEqual(day.field.value, .string("2032-02-29"))
                XCTAssertFalse(country.invalid)
                XCTAssertFalse(day.invalid)
            }
        }
    }

    func testPasswordsStyleCategoriesListsSelectionAndCreationRender() async throws {
        var first = VaultRevision(templateId: "api-credential", title: "Synthetic API", tags: ["Work"], sections: [
            VaultSection(id: "credentials", fields: [
                VaultField(id: "credential", kind: "concealed", value: .string("Synthetic secret"), concealed: true)
            ])
        ])
        first.favorite = true
        let card = VaultRevision(templateId: "credit-card", title: "Synthetic Card")
        let document = VaultRevision(templateId: "document", title: "Synthetic Document")
        var alternative = first
        alternative.revisionId = UUID()
        alternative.title = "Synthetic alternative"
        let heads = [first, card, document, alternative]
        let records = try heads.map(RevisionCodec.encode)
        let session = VaultSession(authenticate: {}, load: { records }, append: { _, _, _ in })
        try await session.unlock()
        let items = LedgerBrowser.items(from: heads)
        try await render(LedgerView(session: session), named: "passwords-three-column-unselected")
        for appearance in [ColorScheme.light, .dark] {
            try await render(LedgerView(session: session), named: "passwords-browser-\(appearance)", appearance: appearance)
        }
        for category in LedgerCategory.allCases {
            try await render(LedgerSidebar(items: items, selection: category, select: { _ in }),
                             named: "passwords-sidebar-\(category.id)")
            for item in items {
                try await render(List { LedgerItemRow(item: item) }, named: "passwords-row-\(item.title)")
            }
        }
        try await render(
            LedgerSidebar(items: items, selection: .all, select: { _ in })
                .environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.layoutDirection, .rightToLeft),
            named: "passwords-categories-largest-rtl", appearance: .dark
        )
        try await render(LedgerView(session: session, browser: LedgerBrowser(selectedRecordId: card.recordId)),
                         named: "passwords-selected-card")
        try await render(LedgerView(session: session, browser: LedgerBrowser(selectedRecordId: first.recordId)),
                         named: "passwords-conflicted-record")
        for query in ["Work", "No matching item"] {
            try await render(LedgerView(session: session, browser: LedgerBrowser(query: query)),
                             named: "passwords-search-\(query)")
        }
        for category in [LedgerCategory.favorites, .conflicts] {
            let empty = VaultSession(authenticate: {}, load: { [] }, append: { _, _, _ in })
            try await empty.unlock()
            try await render(LedgerView(session: empty, browser: LedgerBrowser(category: category)),
                             named: "passwords-empty-\(category.id)")
        }
        try await render(ItemCreationView(category: .records, session: session, saved: { _ in }),
                         named: "passwords-create-type")
        try await render(ItemEditor(revision: document, creating: true, save: { _ in }),
                         named: "passwords-create-editor")
        try await render(TemplatePicker(category: .credentials, select: { _, _ in }),
                         named: "passwords-credential-types")
    }

    func testPickerEditorAndConcealedDetailRenderInBothDirections() async throws {
        let template = try XCTUnwrap(TemplateCatalog.template(id: "secure-note"))
        let revision = VaultRevision(
            templateId: "secure-note", title: "Synthetic test",
            sections: [VaultSection(id: "data", fields: [
                VaultField(id: "note", kind: "text", value: .string("Synthetic private text"), concealed: true),
                VaultField(id: "empty", kind: "text", value: .string(""), concealed: false),
                VaultField(id: "future", kind: "future", value: .object(["safe": .bool(true)]), concealed: true)
            ])]
        )
        try await render(TemplatePicker(select: { _, _ in }))
        try await render(ItemEditor(revision: revision, save: { _ in }))
        try await render(ItemDetailView(revision: revision, conflicted: false, edit: {}, delete: {}))
        try await render(Form {
            EditableField(
                field: .constant(VaultField(
                    id: "public-note", kind: "multiline",
                    value: .string("Line one\nLine two"), concealed: false
                ))
            )
        })
        try await render(
            ItemDetailView(revision: revision, conflicted: true, edit: {}, delete: {})
                .environment(\.layoutDirection, .rightToLeft)
                .environment(\.colorScheme, .dark)
        )
        XCTAssertFalse(template.sections.isEmpty)
    }

    func testPopulatedSelectedCustomFieldFileAndDeleteConflictRender() async throws {
        var stored: [Data] = []
        let session = VaultSession(
            authenticate: {}, load: { stored }, append: { data, _, _ in stored.append(data) }
        )
        try await session.unlock()
        let template = try XCTUnwrap(TemplateCatalog.template(id: "secure-note"))
        var revision = try session.newDraft(template: template)
        revision.title = "Synthetic populated item"
        revision.sections = [VaultSection(id: "synthetic", fields: [
            VaultField(kind: "concealed", value: .string("synthetic-only"), concealed: true, label: "Synthetic key"),
            VaultField(id: "plain", kind: "multiline", value: .string("Line one\nLine two"), concealed: false)
        ])]
        revision.attachments = [AttachmentMetadata(
            blob: EncryptedBlob(blobId: UUID(), key: Data(repeating: 0, count: 32), plaintextSize: 0),
            filename: "Synthetic contract.pdf", mediaType: "application/pdf"
        ).json]
        try session.save(revision)
        XCTAssertEqual(session.visibleItems().map(\.title), ["Synthetic populated item"])
        XCTAssertFalse(session.hasConflict(revision))
        try await render(LedgerView(session: session, selected: revision.revisionId))
        try await render(ItemEditor(revision: revision, save: { _ in }))
        if session.state == .locked { try await session.unlock() }
        var edit = try session.editDraft(revision)
        edit.title = "Synthetic concurrent edit"
        var tombstone = edit
        tombstone.revisionId = UUID()
        tombstone.deleted = true
        stored += [try RevisionCodec.encode(edit), try RevisionCodec.encode(tombstone)]
        session.lock()
        try await session.unlock()
        XCTAssertEqual(session.heads.count, 2)
        XCTAssertTrue(session.hasConflict(tombstone))
        try await render(LedgerView(session: session, selected: tombstone.revisionId))
    }

    func testLargeTextEditorRender() async throws {
        let revision = VaultRevision(
            templateId: "custom-item", title: "Synthetic long title for large text",
            sections: [VaultSection(id: "large-text", fields: [
                VaultField(kind: "concealed", value: .string("synthetic-only"), concealed: true, label: "Synthetic key")
            ])]
        )
        try await render(
            ItemEditor(revision: revision, save: { _ in })
                .environment(\.dynamicTypeSize, .accessibility5)
        )
    }

    func testDisplaySettingsAndNewVersusExistingInputRenderAtEveryFontSize() async throws {
        let suite = "st.rio.miledge.test.display.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let revision = VaultRevision(templateId: "custom-item", title: "Synthetic title", sections: [
            VaultSection(id: "synthetic", fields: [
                VaultField(id: "name", kind: "string", value: .string("Synthetic Name"), concealed: false, label: "Name"),
                VaultField(id: "amount", kind: "number", value: .string("9007199254740993.000001"), concealed: false, label: "Amount"),
                VaultField(id: "key", kind: "key-material", value: .string("Synthetic Key\n0001"), concealed: true, label: "Key")
            ])
        ])
        for size in DisplayTextSize.allCases {
            defaults.set(size.rawValue, forKey: "displayTextSize")
            try await render(DisplaySettingsView().defaultAppStorage(defaults), named: "display-settings-\(size.rawValue)")
            for creating in [false, true] {
                try await render(
                    ItemEditor(revision: revision, creating: creating, copy: { _ in true }, save: { _ in })
                        .displayPreferences().defaultAppStorage(defaults),
                    named: "editor-font-\(size.rawValue)-creating-\(creating)"
                )
            }
        }
    }

    @MainActor @Observable
    final class InputFixture {
        var field: VaultField
        var invalid = false
        init(field: VaultField) { self.field = field }
        var binding: Binding<VaultField> { Binding(get: { self.field }, set: { self.field = $0 }) }
        var validation: Binding<Bool> { Binding(get: { self.invalid }, set: { self.invalid = $0 }) }
    }

    func testMountedInputsObserveExternalReplacementWithoutWritingStaleDraftValues() async throws {
        for kind in VaultEditor.supportedKinds {
            let initial = try VaultEditor.customField(kind: kind, label: "Synthetic replacement", concealed: true)
            let fixture = InputFixture(field: initial)
            let replacement: JSONValue = kind == "boolean" ? .bool(true) : sampleValue(kind: kind)
            let address = kind == "address" ? try AddressFieldDraft(value: initial.value) : nil
            let choices = kind == "multi-select" ? try StringListFieldDraft(value: initial.value) : nil
            let recovery = kind == "recovery-codes" ? try RecoveryCodesFieldDraft(value: initial.value) : nil
            let content = Form {
                if let address {
                    AddressFieldInput(field: fixture.binding, invalid: fixture.validation, draft: address)
                } else if let choices {
                    StringListFieldInput(field: fixture.binding, invalid: fixture.validation, draft: choices)
                } else if let recovery {
                    RecoveryCodesFieldInput(field: fixture.binding, invalid: fixture.validation, draft: recovery)
                } else if kind == "boolean" {
                    BooleanFieldInput(field: fixture.binding, invalid: fixture.validation, value: false)
                } else {
                    StringFieldInput(field: fixture.binding, invalid: fixture.validation, text: "")
                }
            }
            try await render(content, named: "mounted-external-\(kind)") {
                fixture.invalid = true
                fixture.field.value = replacement
                try await Task.sleep(for: .milliseconds(75))
                XCTAssertFalse(fixture.invalid, kind)
                XCTAssertEqual(fixture.field.value, replacement, kind)
                fixture.field.concealed = false
                try await Task.sleep(for: .milliseconds(75))
                fixture.field.concealed = true
                try await Task.sleep(for: .milliseconds(75))
                fixture.field.id = "replacement-\(kind)"
                try await Task.sleep(for: .milliseconds(75))
                XCTAssertEqual(fixture.field.value, replacement, kind)
            }
        }
    }

    #if os(macOS)
    func testInlineTypePickerRendersTemplateAndProviderAtEveryFontSize() async throws {
        for size in DisplayTextSize.allCases {
            for choice in [
                TemplatePickerChoice(templateID: "credit-card", profileID: nil),
                TemplatePickerChoice(templateID: "affiliate-account", profileID: "rakuten-webservice-jp")
            ] {
                try await render(ItemTypePicker(selection: .constant(choice))
                    .environment(\.locale, Locale(identifier: "en"))
                    .environment(\.displayTextSize, size).ledgerFont(.body),
                    named: "inline-type-\(choice.profileID ?? choice.templateID)-\(size.rawValue)")
            }
        }
    }

    func testNativePlainAndSecureFieldsCenterTextAndCaretAtEveryFontSize() async throws {
        for size in DisplayTextSize.allCases {
            let host = NSHostingController(rootView: VStack {
                MacFieldInput(text: .constant(""), label: "Synthetic empty email")
                MacFieldInput(text: .constant("Synthetic text"), label: "Synthetic text")
                MacFieldInput(text: .constant("Synthetic secret"), label: "Synthetic secret", secure: true)
            }.padding().environment(\.displayTextSize, size))
            let window = NSWindow(contentViewController: host)
            window.setContentSize(NSSize(width: 600, height: 240))
            window.isReleasedWhenClosed = false
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            try await Task.sleep(for: .milliseconds(100))
            func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
            let inputs = descendants(host.view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
            XCTAssertEqual(inputs.count, 3)
            for input in inputs {
                let height = max(input.intrinsicContentSize.height, 36 * size.scale)
                // Native layout rounds fractional field heights to adjacent whole points.
                XCTAssertGreaterThanOrEqual(input.frame.height, height.rounded(.down))
                XCTAssertLessThanOrEqual(input.frame.height, height.rounded(.up))
                let drawing = try XCTUnwrap(input.cell).drawingRect(forBounds: input.bounds)
                XCTAssertEqual(drawing.midY, input.bounds.midY, accuracy: 0.5)
                XCTAssertTrue(window.makeFirstResponder(input))
                let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                let editing = input.convert(editor.bounds, from: editor)
                XCTAssertEqual(editing.midY, input.bounds.midY, accuracy: 1)
                let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
                let fieldScreen = window.convertToScreen(input.convert(input.bounds, to: nil))
                XCTAssertEqual(caret.midY, fieldScreen.midY, accuracy: 1.5)
                XCTAssertLessThan(caret.height, fieldScreen.height)
                XCTAssertGreaterThan(caret.height, 0)
            }
            let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            let image = NSImage(size: host.view.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Centered plain and secure fields \(size.rawValue) pt"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testGlobalConcealmentSettingsPreserveMountedInvalidInputAndSavedFlags() async throws {
        let suite = "st.rio.miledge.test.visibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = InputFixture(field: VaultField(
            id: "amount", kind: "number", value: .string("1.00"), concealed: true, label: "Amount"
        ))
        let host = NSHostingController(rootView: Form {
            EditableField(field: fixture.binding, invalid: fixture.validation)
        }.displayPreferences().defaultAppStorage(defaults))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 600, height: 240))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        func input() throws -> NSTextField {
            func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
            return try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        }
        XCTAssertTrue(try input() is NSSecureTextField)
        defaults.set(false, forKey: "concealValuesByDefault")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(try input() is NSSecureTextField)
        let visible = try input()
        visible.stringValue = "invalid-number"
        visible.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: visible))
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(fixture.invalid)
        for conceal in [true, false] {
            defaults.set(conceal, forKey: "concealValuesByDefault")
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(try input() is NSSecureTextField, conceal)
            XCTAssertEqual(try input().stringValue, "invalid-number")
            XCTAssertTrue(fixture.invalid)
            XCTAssertEqual(fixture.field.value, .string("1.00"))
            XCTAssertTrue(fixture.field.concealed)
        }
    }

    func testNativeTitleNameAndNumericInputAlignment() async throws {
        let revision = VaultRevision(templateId: "custom-item", title: "Synthetic title", sections: [
            VaultSection(id: "synthetic", fields: [
                VaultField(id: "name", kind: "string", value: .string("Synthetic Name"), concealed: false, label: "Name"),
                VaultField(id: "amount", kind: "number", value: .string("12345.00"), concealed: false, label: "Amount")
            ])
        ])
        let host = NSHostingController(rootView: ItemEditor(revision: revision, save: { _ in }).ledgerFont(.body))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 900, height: 650))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let inputs = descendants(host.view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        for (text, expected) in [
            ("Synthetic title", NSTextAlignment.left), ("Synthetic Name", .left), ("12345.00", .right)
        ] {
            let input = try XCTUnwrap(inputs.first { $0.stringValue == text }, text)
            XCTAssertEqual(input.alignment, expected, text)
            window.makeFirstResponder(input)
            if let editor = input.currentEditor() as? NSTextView { XCTAssertEqual(editor.alignment, expected, text) }
            XCTAssertEqual(input.frame.height, 36, accuracy: 0.5, text)
        }
        let name = try XCTUnwrap(inputs.first { $0.stringValue == "Synthetic Name" })
        let amount = try XCTUnwrap(inputs.first { $0.stringValue == "12345.00" })
        XCTAssertEqual(name.convert(name.bounds, to: nil).minX, amount.convert(amount.bounds, to: nil).minX, accuracy: 0.5)
    }

    func testNativeInputSourcesFollowFocusBeforeTypingAndDoNotLeakToFreeText() async throws {
        let values = [("number", "-123.000")]
        let host = NSHostingController(rootView: VStack {
            ForEach(values, id: \.0) { entry in
                StringFieldInput(field: .constant(VaultField(
                    kind: entry.0, value: .string(entry.1), concealed: false
                )), invalid: .constant(false), text: entry.1)
            }
            MacFieldInput(text: .constant("架空の氏名"), label: "Synthetic name")
            MacFieldInput(text: .constant("架空の秘密"), label: "Synthetic secret", secure: true)
            TextField("Synthetic address", text: .constant("架空の住所"))
        }.padding())
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 600, height: 500))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let inputs = descendants(host.view).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        for value in values.map(\.1) + ["架空の氏名", "架空の住所", "-123.000"] {
            let input = try XCTUnwrap(inputs.first { $0.stringValue == value })
            XCTAssertTrue(window.makeFirstResponder(input))
            let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
            let expected: [String]? = values.map(\.1).contains(value) ? [NSAllRomanInputSourcesLocaleIdentifier] : nil
            XCTAssertEqual(editor.allowedInputSourceLocales, expected, value)
            XCTAssertEqual(try XCTUnwrap(editor.inputContext).allowedInputSourceLocales, expected, value)
            XCTAssertEqual(editor.string, value)
        }
        let numeric = try XCTUnwrap(inputs.first { $0.stringValue == "-123.000" })
        let sharedEditor = try XCTUnwrap(numeric.currentEditor() as? NSTextView)
        XCTAssertTrue(window.makeFirstResponder(nil))
        XCTAssertNil(sharedEditor.allowedInputSourceLocales)
        let secure = try XCTUnwrap(inputs.first { $0 is NSSecureTextField })
        XCTAssertTrue(window.makeFirstResponder(secure))
        XCTAssertNotNil(secure.currentEditor() as? NSTextView)
        let name = try XCTUnwrap(inputs.first { $0.stringValue == "架空の氏名" })
        XCTAssertTrue(window.makeFirstResponder(name))
        XCTAssertNil(try XCTUnwrap(name.currentEditor() as? NSTextView).allowedInputSourceLocales)
    }

    func testFocusedInputSourcePolicyChangesPreserveMarkedTextAndExactBuffers() async throws {
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let host = NSHostingController(rootView: MacFieldInput(
            text: binding, label: "Synthetic source policy"
        ).padding())
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 600, height: 240))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(input))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        MacFieldInputSource.unrestricted.apply(to: editor)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.string, "かな")
        editor.unmarkText()
        editor.insertText("-9007199254740993.00000100",
                          replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(input.currentEditor() === editor)
        for kind in ["number", "date", "year-month", "string"] {
            host.rootView = MacFieldInput(
                text: binding, label: "Synthetic source policy",
                inputSource: FieldPresentation.usesRomanInput(for: kind) ? .roman : .unrestricted
            ).padding()
            try await Task.sleep(for: .milliseconds(75))
            XCTAssertTrue(input.currentEditor() === editor)
            XCTAssertEqual(editor.allowedInputSourceLocales,
                           kind == "string" ? nil : [NSAllRomanInputSourcesLocaleIdentifier])
            XCTAssertEqual(input.stringValue, "-9007199254740993.00000100")
            XCTAssertEqual(text, "-9007199254740993.00000100")
        }
    }

    func testRestrictedMultilinePastePreservesInvalidBufferAndNativeEditing() async throws {
        let fixture = InputFixture(field: VaultField(kind: "number", value: .string("-1.000"), concealed: false))
        let host = NSHostingController(rootView: StringFieldInput(
            field: fixture.binding, invalid: fixture.validation, text: "-1.000"
        ).padding().frame(width: 600, height: 300))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 600, height: 300))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        let pasted = "１２３\r\ninvalid-number\n"
        input.stringValue = pasted
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextView }.first { $0.isEditable })
        XCTAssertEqual(editor.string, pasted)
        XCTAssertEqual(editor.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier])
        XCTAssertTrue(fixture.invalid)
        XCTAssertEqual(fixture.field.value, .string("-1.000"))
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertGreaterThan(editor.visibleRect.height, 0)
        XCTAssertGreaterThan(editor.visibleRect.width, 0)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let viewport = window.convertToScreen(scroll.contentView.convert(scroll.contentView.bounds, to: nil))
        let firstCharacter = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(firstCharacter), "\(firstCharacter) within \(viewport)")
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertFalse(editor.isRichText)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
        let attachment = XCTAttachment(
            data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])), uniformTypeIdentifier: "public.png"
        )
        attachment.name = "Synthetic invalid multiline numeric input"
        attachment.lifetime = .keepAlways
        add(attachment)
        editor.insertText("追加\n", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertEqual(editor.string, pasted + "追加\n")
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, pasted)
        editor.insertText("-9007199254740993.00000100",
                          replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(fixture.invalid)
        XCTAssertEqual(fixture.field.value, .string("-9007199254740993.00000100"))
        let corrected = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(corrected))
        XCTAssertEqual(try XCTUnwrap(corrected.currentEditor() as? NSTextView).allowedInputSourceLocales,
                       [NSAllRomanInputSourcesLocaleIdentifier])
    }

    func testNativeInputChangesKeepInvalidBuffersAndDisableAutomaticTextAlteration() async throws {
        let suite = "st.rio.miledge.test.input-font.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(DisplayTextSize.standard.rawValue, forKey: "displayTextSize")
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = InputFixture(field: VaultField(id: "amount", kind: "number", value: .string("12345.00"), concealed: false))
        let host = NSHostingController(rootView: Form {
            StringFieldInput(field: fixture.binding, invalid: fixture.validation, text: "12345.00")
        }.displayPreferences().defaultAppStorage(defaults))
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 600, height: 400))
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        func descendants(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSTextField }.first { $0.isEditable })
        window.makeFirstResponder(input)
        input.delegate?.controlTextDidBeginEditing?(Notification(name: NSControl.textDidBeginEditingNotification, object: input))
        let editor = try XCTUnwrap(input.currentEditor() as? NSTextView)
        XCTAssertEqual(editor.allowedInputSourceLocales, [NSAllRomanInputSourcesLocaleIdentifier])
        XCTAssertTrue(editor.allowsUndo)
        XCTAssertFalse(editor.isAutomaticSpellingCorrectionEnabled)
        XCTAssertFalse(editor.isAutomaticTextReplacementEnabled)
        XCTAssertFalse(editor.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticDashSubstitutionEnabled)
        XCTAssertFalse(editor.isAutomaticTextCompletionEnabled)
        input.stringValue = "invalid-number"
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(fixture.invalid)
        XCTAssertEqual(fixture.field.value, .string("12345.00"))
        XCTAssertEqual(input.stringValue, "invalid-number")
        defaults.set(DisplayTextSize.largest.rawValue, forKey: "displayTextSize")
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(fixture.invalid)
        XCTAssertEqual(input.stringValue, "invalid-number")
        XCTAssertEqual(input.font?.pointSize, CGFloat(DisplayTextSize.largest.rawValue))
        XCTAssertEqual(input.frame.height, 36 * DisplayTextSize.largest.scale, accuracy: 0.5)
        XCTAssertEqual(input.convert(editor.bounds, from: editor).midY, input.bounds.midY, accuracy: 1)
        input.stringValue = "9007199254740993.000001"
        input.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: input))
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertFalse(fixture.invalid)
        XCTAssertEqual(fixture.field.value, .string("9007199254740993.000001"))
    }
    #endif

    #if os(iOS)
    func testMobileInputChangesKeepInvalidBuffersAcrossFontUpdates() async throws {
        let suite = "st.rio.miledge.test.input-font.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(DisplayTextSize.standard.rawValue, forKey: "displayTextSize")
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = InputFixture(field: VaultField(id: "amount", kind: "number", value: .string("12345.00"), concealed: false))
        let host = UIHostingController(rootView: Form {
            EditableField(field: fixture.binding, invalid: fixture.validation, copy: { _ in true })
        }.displayPreferences().defaultAppStorage(defaults)
            .environment(\.horizontalSizeClass, .compact).environment(\.dynamicTypeSize, .large))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKey() }
        try await Task.sleep(for: .milliseconds(200))
        func descendants(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap(descendants) }
        let input = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first)
        XCTAssertEqual(input.textAlignment, .right)
        XCTAssertEqual(input.autocorrectionType, .no)
        XCTAssertEqual(input.autocapitalizationType, .none)
        input.text = "invalid-number"
        input.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertTrue(fixture.invalid)
        XCTAssertEqual(fixture.field.value, .string("12345.00"))
        defaults.set(DisplayTextSize.largest.rawValue, forKey: "displayTextSize")
        try await Task.sleep(for: .milliseconds(75))
        let resizedInput = try XCTUnwrap(descendants(host.view).compactMap { $0 as? UITextField }.first)
        XCTAssertTrue(fixture.invalid)
        XCTAssertEqual(resizedInput.text, "invalid-number")
        XCTAssertEqual(resizedInput.font?.pointSize, CGFloat(DisplayTextSize.largest.rawValue))
        XCTAssertGreaterThan(resizedInput.bounds.width, 200)
        resizedInput.text = "9007199254740993.000001"
        resizedInput.sendActions(for: .editingChanged)
        try await Task.sleep(for: .milliseconds(75))
        XCTAssertFalse(fixture.invalid)
        XCTAssertEqual(fixture.field.value, .string("9007199254740993.000001"))
    }

    func testCompactEditorRendersCombinedLargestAppAndSystemFonts() async throws {
        let fixture = InputFixture(field: VaultField(id: "key", kind: "key-material", value: .string("Synthetic key"), concealed: true))
        try await render(Form {
            EditableField(field: fixture.binding, invalid: fixture.validation, copy: { _ in true })
        }.ledgerFont(.body).environment(\.displayTextSize, .largest)
            .environment(\.dynamicTypeSize, .accessibility5)
            .environment(\.horizontalSizeClass, .compact), named: "combined-largest-font-compact-editor")
        XCTAssertEqual(fixture.field.value, .string("Synthetic key"))
    }
    #endif

    #if os(macOS)
    func testEditorSheetBoundsAndScrollRangeFollowChangingFieldCounts() async throws {
        var revision = VaultRevision(templateId: "custom-item", title: "Synthetic layout", sections: [
            VaultSection(id: "custom", fields: [
                VaultField(id: "choices", kind: "multi-select", value: .array([.string("0001")]),
                           concealed: false, label: "Choices")
            ])
        ])
        let controller = NSHostingController(rootView: editorSheet(revision))
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.appearance = NSAppearance(named: .aqua)
        parent.contentViewController = controller
        parent.center()
        parent.makeKeyAndOrderFront(nil)
        defer {
            if let sheet = parent.attachedSheet { parent.endSheet(sheet) }
            parent.close()
        }
        for _ in 0..<20 {
            if parent.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let sheet = try XCTUnwrap(parent.attachedSheet)
        XCTAssertGreaterThanOrEqual(parent.contentLayoutRect.height, 520)
        let initialSize = sheet.frame.size
        let screen = try XCTUnwrap(parent.screen)
        var shortHeight: CGFloat?
        var longHeight: CGFloat?
        for (fieldCount, choiceCount) in [(1, 1), (1, 12), (1, 2), (12, 1), (2, 1), (24, 1), (1, 24), (1, 1)] {
            revision.revisionId = UUID()
            revision.sections[0].fields = [
                VaultField(id: "choices", kind: "multi-select",
                           value: .array(Array(repeating: .string("Synthetic choice"), count: choiceCount)),
                           concealed: false, label: "Choices")
            ] + (1..<fieldCount).map { index in
                VaultField(id: UUID().uuidString, kind: "string", value: .string("Synthetic value"),
                           concealed: false, label: "Synthetic field \(index)")
            }
            controller.rootView = editorSheet(revision)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertTrue(parent.attachedSheet === sheet)
            XCTAssertLessThanOrEqual(sheet.frame.height, screen.visibleFrame.height)
            XCTAssertEqual(sheet.frame.size, initialSize)
            XCTAssertTrue(screen.visibleFrame.contains(sheet.frame))
            let content = try XCTUnwrap(sheet.contentView)
            func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }
            let scroll = try XCTUnwrap(views(content).compactMap { $0 as? NSScrollView }.max {
                $0.frame.height < $1.frame.height
            })
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertTrue(content.bounds.contains(scroll.convert(scroll.bounds, to: content)))
            XCTAssertLessThan(scroll.frame.height, content.bounds.height)
            if fieldCount == 1 && choiceCount == 1 { shortHeight = document.bounds.height }
            if choiceCount == 24 { longHeight = document.bounds.height }
            if fieldCount >= 12 || choiceCount >= 12 {
                XCTAssertGreaterThan(document.bounds.height, scroll.contentView.bounds.height)
                let upper = document.bounds.maxY - scroll.contentView.bounds.height
                document.scroll(NSPoint(x: 0, y: upper))
                let end = scroll.documentVisibleRect.minY
                document.scroll(NSPoint(x: 0, y: document.bounds.minY))
                XCTAssertEqual(abs(end - scroll.documentVisibleRect.minY),
                               document.bounds.height - scroll.contentView.bounds.height, accuracy: 1)
            }
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let image = NSImage(size: content.bounds.size)
            image.addRepresentation(bitmap)
            let attachment = XCTAttachment(image: image)
            attachment.name = "Synthetic actual editor sheet — \(fieldCount) fields, \(choiceCount) choices"
            attachment.lifetime = .keepAlways
            add(attachment)
            if choiceCount == 1 && [1, 24].contains(fieldCount) {
                try await captureOwnWindow(sheet, named: "Native synthetic sheet — \(fieldCount) fields")
            }
        }
        XCTAssertGreaterThan(try XCTUnwrap(longHeight), try XCTUnwrap(shortHeight))
    }

    private func editorSheet(_ revision: VaultRevision) -> some View {
        SheetFixture {
            ItemEditor(revision: revision, save: { _ in XCTFail("This test changes layout state, not saved data.") })
                .id(revision.revisionId)
        }
    }

    private func captureOwnWindow(_ window: NSWindow, named name: String) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            let attachment = XCTAttachment(string: "Native-window capture blocked by existing permission; no access requested. Hosted bitmap and layout metrics are not whole-window visual approval.")
            attachment.name = "\(name) — capture blocked"
            attachment.lifetime = .keepAlways
            add(attachment)
            return
        }
        let available = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = try XCTUnwrap(available.windows.first {
            $0.windowID == CGWindowID(window.windowNumber)
                && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
        }, "Only this test's synthetic sheet may be captured.")
        let configuration = SCStreamConfiguration()
        configuration.width = Int(target.frame.width * window.backingScaleFactor)
        configuration.height = Int(target.frame.height * window.backingScaleFactor)
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration
        )
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: target.frame.size))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    #endif

    func testEditorSectionHierarchyAndLongMultilineFieldsRender() async throws {
        let revision = VaultRevision(templateId: "api-credential", title: "Synthetic layout", sections: [
            VaultSection(id: "credentials", fields: [
                VaultField(id: "provider", kind: "string", value: .string("Synthetic provider"), concealed: false)
            ]),
            VaultSection(id: "notes", fields: [
                VaultField(id: "notes", kind: "multiline",
                           value: .string(Array(repeating: "Synthetic long line", count: 50).joined(separator: "\n")),
                           concealed: false, label: "Notes")
            ]),
            VaultSection(id: "optional", fields: [
                VaultField(id: "host", kind: "string", value: .string("Synthetic host"), concealed: false)
            ]),
            VaultSection(id: "original-notation", fields: [
                VaultField(id: "originalDateNotation", kind: "string", value: .string("Synthetic date"), concealed: false)
            ]),
            VaultSection(id: "profile:id-secret-pair:credentials", fields: [
                VaultField(id: "credentialId", kind: "string", value: .string("Synthetic ID"), concealed: true)
            ]),
            VaultSection(id: UUID().uuidString, fields: [
                VaultField(id: UUID().uuidString, kind: "string", value: .string("Synthetic custom value"),
                           concealed: false, label: "Synthetic custom field")
            ])
        ])
        for appearance in [ColorScheme.light, .dark] {
            try await render(ItemEditor(revision: revision, save: { _ in }),
                             named: "editor-section-hierarchy-\(appearance)", appearance: appearance)
            try await render(
                ItemEditor(revision: revision, save: { _ in })
                    .environment(\.dynamicTypeSize, .accessibility5)
                    .environment(\.layoutDirection, .rightToLeft),
                named: "editor-section-hierarchy-largest-rtl-\(appearance)", appearance: appearance
            )
        }
    }

    func testOrganizationControlsAndDetailsRenderWithExactUserLabels() async throws {
        var revision = VaultRevision(
            title: "Synthetic organization", tags: ["  Exact Case  ", "العربية", "日本語", "A", "A"],
            favorite: true
        )
        try await render(Form {
            ItemOrganizationInput(tags: .constant(revision.tags), favorite: .constant(true), expanded: true)
        }, named: "organization-expanded")
        try await render(ItemDetailView(revision: revision, conflicted: false, edit: {}, delete: {}),
                         named: "organization-detail")
        try await render(Form {
            ItemOrganizationInput(tags: .constant([]), favorite: .constant(false))
        }, named: "organization-collapsed")
        try await render(Form {
            ItemOrganizationInput(tags: .constant(revision.tags), favorite: .constant(true), expanded: true)
        }.environment(\.dynamicTypeSize, .accessibility5).environment(\.layoutDirection, .rightToLeft)
            .environment(\.colorScheme, .dark), named: "organization-large-rtl")
        revision.schemaVersion = 999
        try await render(ItemEditor(revision: revision, save: { _ in XCTFail("Read-only records cannot save") }),
                         named: "organization-read-only")
    }

    #if os(macOS)
    private struct SheetFixture<Content: View>: View {
        @ViewBuilder let content: () -> Content
        @State private var presented = false

        var body: some View {
            Color.clear
                .frame(minWidth: 800, minHeight: 520)
                .sheet(isPresented: $presented) { content() }
                .onAppear { presented = true }
        }
    }
    #endif

    func testRelatedItemsRenderDuplicatesUnavailableConflictsAndAdaptiveSelection() async throws {
        let target = VaultRevision(title: "Synthetic related item")
        let missing = UUID()
        var deleted = VaultRevision(title: "Deleted")
        deleted.deleted = true
        let conflicting = VaultRevision(title: "Concurrent")
        var alternate = conflicting
        alternate.revisionId = UUID()
        var future = VaultRevision(title: "Synthetic read-only target")
        future.schemaVersion = 999
        let items = [target, deleted, conflicting, alternate, future]
        let revision = VaultRevision(
            title: "Synthetic source", linkedRecordIds: [
                target.recordId, target.recordId, missing, deleted.recordId, conflicting.recordId, future.recordId
            ]
        )
        try await render(Form {
            ItemRelatedItemsInput(recordIds: .constant(revision.linkedRecordIds),
                                  recordId: revision.recordId, items: items, expanded: true)
        }, named: "related-expanded")
        try await render(Form {
            ItemRelatedItemsInput(recordIds: .constant([]), recordId: revision.recordId, items: [])
        }, named: "related-collapsed")
        try await render(RelatedItemPicker(items: items, excluded: [target.recordId], select: { _ in }),
                         named: "related-picker")
        try await render(RelatedItemPicker(items: [], excluded: [], select: { _ in }), named: "related-no-choices")
        try await render(ItemDetailView(
            revision: revision, conflicted: false, edit: {}, delete: {}, relatedItems: items, openRelated: { _ in }
        ), named: "related-detail")
        try await render(ItemDetailView(
            revision: revision, conflicted: false, edit: {}, delete: {}, relatedItems: items
        ), named: "related-static-detail")
        try await render(Form {
            ItemRelatedItemsInput(recordIds: .constant(revision.linkedRecordIds),
                                  recordId: revision.recordId, items: items, expanded: true)
        }.environment(\.dynamicTypeSize, .accessibility5).environment(\.layoutDirection, .rightToLeft)
            .environment(\.colorScheme, .dark), named: "related-large-rtl")
    }

    func testRelatedPickerRendersTitleTagIdentityAndNoMatchQueries() async throws {
        let target = VaultRevision(
            title: "Synthetic searchable target", tags: ["Exact tag"],
            sections: [VaultSection(id: "synthetic", fields: [
                VaultField(kind: "concealed", value: .string("Never search this secret"), concealed: true)
            ])]
        )
        for (name, query) in [
            ("title", "searchable"), ("tag", "exact TAG"), ("identity", target.recordId.uuidString),
            ("no-match", "Never search this secret")
        ] {
            try await render(
                RelatedItemPicker(items: [target], excluded: [], select: { _ in }, query: query),
                named: "related-search-\(name)"
            )
        }
        let source = VaultRevision(
            title: "Synthetic unorganized source", tags: ["Synthetic tag"],
            linkedRecordIds: [target.recordId]
        )
        try await render(ItemDetailView(
            revision: source, conflicted: false, edit: {}, delete: {}, relatedItems: [target], openRelated: { _ in }
        ), named: "related-with-organization")
    }

    func testCopyControlsFeedbackAndClipboardErrorsRenderWithoutSecretDisclosure() async throws {
        let field = VaultField(
            id: "key", kind: "key-material", value: .string("Synthetic concealed clipboard key"),
            concealed: true, label: "Synthetic key"
        )
        try await render(Form { FieldDetailRow(field: field, copy: { _ in true }) }, named: "copy-concealed")
        try await render(Form { FieldDetailRow(field: field, copy: { _ in true }, copied: true) },
                         named: "copy-feedback")
        var structured = field
        structured.value = .object(["postalCode": .string("000001")])
        try await render(Form { FieldDetailRow(field: structured, copy: { _ in true }) }, named: "copy-json")
        try await render(Form {
            FieldDetailRow(field: structured, copy: { _ in true })
        }.environment(\.dynamicTypeSize, .accessibility5).environment(\.layoutDirection, .rightToLeft)
            .environment(\.colorScheme, .dark), named: "copy-large-rtl")
        let clipboard = SecureClipboard(write: { _, _, _ in }, clear: { _ in })
        let session = VaultSession(authenticate: {}, load: { [] }, append: { _, _, _ in })
        for issue in [ClipboardIssue.copyFailed, .clearingFailed] {
            clipboard.issue = issue
            try await render(LedgerView(session: session, clipboard: clipboard), named: "copy-error-\(issue)")
        }
    }

    func testConflictReviewRendersChoicesWholeVersionsAndBlockedStates() async throws {
        var first = VaultRevision(title: "Synthetic competing version", sections: [
            VaultSection(id: "secret", fields: [
                VaultField(id: "key", kind: "key-material", value: .string("Synthetic concealed key"), concealed: true)
            ])
        ])
        first.linkedRecordIds = [first.recordId, UUID()]
        var second = first
        second.revisionId = UUID()
        second.title = "Synthetic alternative"
        let versions = [first, second]
        try await render(ConflictResolver(versions: versions, reload: { versions }, resolve: { _, _ in }),
                         named: "conflict-choices")
        try await render(ConflictResolver(
            versions: versions, selected: first.revisionId, reload: { versions }, resolve: { _, _ in }
        ), named: "conflict-review")
        second.deleted = true
        let deletion = [first, second]
        try await render(ConflictResolver(
            versions: deletion, selected: second.revisionId, reload: { deletion }, resolve: { _, _ in }
        ), named: "conflict-deletion-review")
        second.schemaVersion = 999
        let unsupported = [first, second]
        try await render(ConflictResolver(
            versions: unsupported, reload: { unsupported }, resolve: { _, _ in }
        ), named: "conflict-unsupported")
        second.schemaVersion = 1
        second.storageScope = .synchronizable
        try await render(ConflictResolver(
            versions: [first, second], reload: { [] }, resolve: { _, _ in }
        ), named: "conflict-mixed-scope")
        try await render(ConflictResolver(versions: [], reload: { [] }, resolve: { _, _ in }),
                         named: "conflict-resolved-elsewhere")
        try await render(ConflictResolver(
            versions: versions, reload: { versions }, resolve: { _, _ in }
        ).environment(\.dynamicTypeSize, .accessibility5).environment(\.layoutDirection, .rightToLeft)
            .environment(\.colorScheme, .dark), named: "conflict-large-rtl")
        let records = try versions.map(RevisionCodec.encode)
        let session = VaultSession(authenticate: {}, load: { records }, append: { _, _, _ in })
        try await session.unlock()
        try await render(LedgerView(session: session, selected: first.revisionId), named: "conflict-ledger")
    }

    private func sampleValue(kind: String) -> JSONValue {
        switch kind {
        case "address": .object(["custom locality": .string("Synthetic city"), "postalCode": .string("000001")])
        case "multi-select": .array([.string("B"), .string("A"), .string("A")])
        case "recovery-codes": .array([
            .object(["id": .string("stable"), "code": .string(" 0001 "), "used": .bool(true)])
        ])
        case "boolean": .bool(false)
        case "number": .string("9007199254740993.000001")
        case "date": .string("2026-10-10")
        case "year-month": .string("2026-10")
        case "key-material", "multiline": .string("Exact Case\n001\nLine three")
        default: .string("  Exact Case 001  ")
        }
    }

    func testEverySupportedTypedControlAndValueRendersWithConcealment() async throws {
        for kind in VaultEditor.supportedKinds {
            var field = try VaultEditor.customField(kind: kind, label: "Synthetic \(kind)", concealed: false)
            field = try VaultEditor.replacingValue(in: field, with: sampleValue(kind: kind))
            try await render(Form { EditableField(field: .constant(field)) }, named: "\(kind)-input")
            try await render(Form { FieldDetailRow(field: field) }, named: "\(kind)-detail")
            field.concealed = true
            try await render(Form { EditableField(field: .constant(field)) }, named: "\(kind)-concealed")
        }
    }

    func testUnsupportedShapesAndInlineFormatErrorsRenderWithoutConversion() async throws {
        for kind in ["address", "multi-select", "recovery-codes", "boolean", "string"] {
            let field = VaultField(kind: kind, value: .null, concealed: true, label: "Synthetic unsupported")
            try await render(Form { EditableField(field: .constant(field)) })
            XCTAssertEqual(field.value, .null)
        }
        for kind in ["date", "year-month", "number", "string"] {
            let field = try VaultEditor.customField(kind: kind, label: "Synthetic invalid", concealed: false)
            try await render(Form {
                StringFieldInput(field: .constant(field), invalid: .constant(true), text: "invalid-format")
            })
        }
        let field = try VaultEditor.customField(kind: "boolean", label: "Synthetic invalid")
        try await render(Form {
            BooleanFieldInput(field: .constant(field), invalid: .constant(true), value: false)
        })
        try await render(Form {
            FieldValueView(value: .object([
                "flag": .bool(true), "number": .number("9007199254740993"), "null": .null,
                "future": .array([.string("Synthetic nested value")])
            ]))
        })
        try await render(Form {
            FieldValueView(value: .array([
                .object(["id": .string("empty"), "code": .string(""), "used": .bool(false)]),
                .object(["id": .string("new"), "code": .string("0002"), "used": .bool(false)]),
                .object(["id": .string("future"), "code": .string(""), "used": .bool(false),
                         "future": .string("Synthetic unknown property")])
            ]), kind: "recovery-codes")
        }, named: "recovery-codes-empty-and-unknown-detail")
    }

    func testBackupEntryGeneratedPassphraseAndLargeTextRender() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let attachments = AttachmentService(store: try EncryptedBlobStore(directory: directory))
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let session = VaultSession(authenticate: {}, load: { [] }, append: { _, _, _ in })
        try await session.unlock()
        let service = BackupService(session: session, attachments: attachments)
        let flow = BackupFlow(mode: .export, session: session, service: service)
        try await render(BackupView(flow: flow), named: "backup-export-entry")
        let invalid = BackupFlow(mode: .export, session: session, service: service)
        invalid.passphrase = "short"
        invalid.confirmation = "not the same"
        try await render(BackupView(flow: invalid), named: "backup-export-invalid")
        let generated = BackupFlow(mode: .export, session: session, service: service)
        generated.generatePassphrase()
        try await render(
            BackupView(flow: generated).environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.layoutDirection, .rightToLeft).environment(\.colorScheme, .dark),
            named: "backup-export-generated-large-rtl"
        )
        let importing = BackupFlow(mode: .restore, session: session, service: service)
        importing.selectFile(.success(directory.appendingPathComponent("Synthetic.miledge-backup")))
        try await render(BackupView(flow: importing), named: "backup-restore-entry")
    }

    func testBackupReadyPreviewAndCompletedStatesRenderWithoutSecretValues() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let attachments = AttachmentService(store: try EncryptedBlobStore(directory: directory))
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        var records: [Data] = []
        let session = VaultSession(authenticate: {}, load: { records }, append: { data, _, _ in records.append(data) })
        try await session.unlock()
        let service = BackupService(session: session, attachments: attachments)
        let phrase = "Synthetic-backup-passphrase-0123456789"
        let export = BackupFlow(mode: .export, session: session, service: service)
        export.passphrase = phrase
        export.confirmation = phrase
        try await XCTUnwrap(export.prepare()).value
        try await render(BackupView(flow: export), named: "backup-export-ready")
        let saved = BackupFlow(mode: .export, session: session, service: service)
        saved.passphrase = phrase
        saved.confirmation = phrase
        try await XCTUnwrap(saved.prepare()).value
        saved.exportCompleted(.success(directory), attempt: saved.attempt)
        try await render(BackupView(flow: saved), named: "backup-export-saved")
        let revision = VaultRevision(title: "Synthetic restore item", sections: [
            VaultSection(id: "synthetic", fields: [
                VaultField(kind: "concealed", value: .string("Synthetic concealed backup value"), concealed: true)
            ])
        ])
        let backup = try VaultBackup(revisions: [revision], blobs: [])
        let restoring = BackupFlow(
            mode: .restore, session: session, service: service, decrypt: { _, _ in backup }
        )
        restoring.selectFile(.success(directory))
        restoring.passphrase = phrase
        try await XCTUnwrap(restoring.prepare()).value
        try await render(
            BackupView(flow: restoring).environment(\.dynamicTypeSize, .accessibility5)
                .environment(\.layoutDirection, .rightToLeft).environment(\.colorScheme, .dark),
            named: "backup-preview-large-rtl"
        )
        let restored = BackupFlow(
            mode: .restore, session: session, service: service, decrypt: { _, _ in backup }
        )
        restored.selectFile(.success(directory))
        restored.passphrase = phrase
        try await XCTUnwrap(restored.prepare()).value
        try await XCTUnwrap(restored.restoreSelected()).value
        try await render(BackupView(flow: restored), named: "backup-restored")
    }

    func testValueVisibilityAndScopedFieldIdentity() {
        XCTAssertFalse(FieldValueView.hasContent(.object(["empty": .string("")])))
        XCTAssertFalse(FieldValueView.hasContent(.array([.null, .string("")])))
        XCTAssertFalse(FieldValueView.hasContent(.null))
        XCTAssertFalse(FieldValueView.hasContent(.string("")))
        XCTAssertTrue(FieldValueView.hasContent(.bool(false)))
        XCTAssertTrue(FieldValueView.hasContent(.number("0")))
        XCTAssertTrue(FieldValueView.hasContent(.array([.string("0")])))
        XCTAssertTrue(FieldValueView.hasContent(.object(["postalCode": .string("000001")])))
        let emptyCode = JSONValue.object([
            "id": .string("stable"), "code": .string(""), "used": .bool(false)
        ])
        XCTAssertFalse(FieldValueView.hasContent(
            VaultField(kind: "recovery-codes", value: .array([emptyCode]))
        ))
        XCTAssertTrue(FieldValueView.hasContent(
            VaultField(kind: "recovery-codes", value: sampleValue(kind: "recovery-codes"))
        ))
        XCTAssertTrue(FieldValueView.hasContent(
            VaultField(kind: "recovery-codes", value: .array([.object([
                "future": .string("Retain unknown data")
            ])]))
        ))
        XCTAssertTrue(FieldValueView.hasContent(VaultField(kind: "boolean", value: .bool(false))))
        XCTAssertNotEqual(
            EditorFieldID(section: "first", field: "secret"),
            EditorFieldID(section: "second", field: "secret")
        )
        for kind in VaultEditor.supportedKinds {
            XCTAssertNotEqual(FieldKindName.name(for: kind), LocalizedStringKey("Unsupported field"))
        }
        XCTAssertEqual(FieldKindName.name(for: "future"), LocalizedStringKey("Unsupported field"))
    }
}
