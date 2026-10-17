#if os(iOS)
import SwiftUI
import UIKit

/// UIKit owns the floating menu's appearance, placement and dismissal.
/// Only our secure-copy action is offered; no automatic text/data actions.
struct FieldCopyEditMenu: UIViewRepresentable {
    @Binding var presented: Bool
    let title: String
    let copy: () -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.addInteraction(context.coordinator.interaction)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if presented, !coordinator.showing {
            coordinator.showing = true
            // Wait for SwiftUI to lay out the newly revealed value before anchoring.
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, let coordinator, coordinator.parent.presented, view.window != nil else { return }
                coordinator.interaction.presentEditMenu(with: UIEditMenuConfiguration(
                    identifier: nil, sourcePoint: CGPoint(x: view.bounds.midX, y: view.bounds.midY)
                ))
            }
        } else if !presented, coordinator.showing {
            coordinator.interaction.dismissMenu()
            coordinator.showing = false
        }
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.interaction.dismissMenu()
    }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency UIEditMenuInteractionDelegate {
        var parent: FieldCopyEditMenu
        var showing = false
        lazy var interaction = UIEditMenuInteraction(delegate: self)
        init(parent: FieldCopyEditMenu) { self.parent = parent }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                 menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            UIMenu(children: [UIAction(title: parent.title, image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.parent.copy()
            }])
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                 targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
            interaction.view?.bounds ?? .zero
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                                 willDismissMenuFor configuration: UIEditMenuConfiguration,
                                 animator: any UIEditMenuInteractionAnimating) {
            animator.addCompletion { [weak self] in
                guard let self else { return }
                showing = false
                parent.presented = false
                parent.dismiss()
            }
        }
    }
}
#endif
