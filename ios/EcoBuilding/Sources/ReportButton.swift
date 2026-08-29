import QuickLook
import SwiftUI
import UIKit

/// Obtenir la fiche PDF — **l'élément le plus visible de l'écran**.
///
/// C'est l'objet que l'utilisateur emporte : celui qu'il envoie à un notaire, à
/// un artisan, ou qu'il garde avant une visite. Tout le reste de la fiche sert à
/// donner envie de l'obtenir ; ce bouton ne doit donc jamais être une ligne
/// discrète en bas d'écran.
///
/// La génération prend 10 à 45 s côté serveur (données, rendu 3D, mise en page).
/// On annonce les étapes réelles plutôt qu'une barre de progression lisse, qui
/// serait une fiction : un rendu serveur unique n'expose aucune progression.
struct ReportButton: View {
    @ObservedObject var model: BuildingModel
    var autoStart: Binding<Bool> = .constant(false)
    @State private var phase: Phase = .idle
    @State private var elapsed = 0
    @State private var pdf: URL?
    @State private var timer: Timer?
    @State private var quota: API.Quota?
    /// Angle de la flèche pendant la préparation. Une icône figée dix à
    /// quarante-cinq secondes laisse croire que rien ne se passe — le
    /// mouvement est ce qui distingue « ça travaille » de « c'est bloqué ».
    @State private var spinning = false

    enum Phase: Equatable {
        case idle, running, failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: download) {
                HStack(spacing: 10) {
                    Image(systemName: phase == .running
                          ? "arrow.triangle.2.circlepath" : "doc.text.fill")
                        .rotationEffect(.degrees(spinning ? 360 : 0))
                        .animation(spinning
                                   ? .linear(duration: 1).repeatForever(autoreverses: false)
                                   : .default, value: spinning)
                    Text(phase == .running ? stageLabel : t("get_report"))
                        .fontWeight(.semibold)
                    Spacer()
                    if phase == .running {
                        Text("\(elapsed) s").font(.footnote).opacity(0.8)
                    }
                }
                .padding(.vertical, 14).padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.17, green: 0.48, blue: 0.29),
                            in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
            }
            .disabled(phase == .running || model.buildingID == nil)

            if phase == .failed {
                Text(t("report_failed"))
                    .font(.footnote).foregroundStyle(.orange)
            } else if let left = quota?.summary(for: model.buildingID) {
                // Dire ce qu'il reste AVANT d'en manquer : on découvrait la
                // limite en la heurtant. Aucun prix affiché tant que le mur
                // payant n'existe pas — annoncer un tarif qu'on ne peut pas
                // encaisser serait un mensonge.
                Text(left)
                    .font(.footnote)
                    .foregroundStyle(quota?.blocked == true ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // PLEIN ÉCRAN, et non une feuille : la bande de carte laissée visible
        // en haut donnait à croire qu'on pouvait y revenir en la touchant, ce
        // qu'une feuille système ne permet pas. Ou l'on voit la carte et on
        // peut la toucher, ou on ne la voit pas.
        .fullScreenCover(item: $pdf) { url in PDFPreview(url: url) }
        .task { quota = try? await API.quota() }
        // Double appui sur la carte : la fiche part dès que le bâtiment a
        // répondu, sans passer par le bouton.
        .onChange(of: model.buildingID) { id in
            if autoStart.wrappedValue, id != nil, phase != .running {
                autoStart.wrappedValue = false
                download()
            }
        }
    }

    private var stageLabel: String {
        // Étapes calées sur les durées réelles observées côté serveur.
        switch elapsed {
        case ..<3: return t("stage_collect")
        case 3..<12: return t("stage_render")
        default: return t("stage_layout")
        }
    }

    private func download() {
        guard let id = model.buildingID else { return }
        phase = .running
        spinning = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in elapsed += 1 }
        }
        Task {
            defer { timer?.invalidate() }
            do {
                let url = try await API.report(buildingID: id, lon: model.lon, lat: model.lat)
                phase = .idle
                spinning = false
                pdf = url                       // ouvre le lecteur
                quota = try? await API.quota()  // le solde vient de changer
            } catch {
                phase = .failed
                spinning = false
            }
        }
    }
}

/// Lecteur natif d'iOS : la fiche s'AFFICHE tout de suite.
///
/// La feuille de partage seule obligeait à enregistrer dans Fichiers puis à
/// rouvrir depuis le gestionnaire de fichiers, qui la confiait à un navigateur —
/// trois étapes et une sortie de l'app pour voir ce qu'on vient de payer. Ici la
/// fiche s'ouvre directement, et le bouton de partage du lecteur permet ensuite
/// de l'envoyer à un client ou de l'enregistrer.
struct PDFPreview: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // En-tête À NOUS. La croix posée sur le QLPreviewController n'était
            // jamais rendue : celui-ci gère sa propre barre et masque celle
            // qu'on lui fournit. L'utilisateur restait coincé sur le document
            // qu'il venait d'obtenir, juste après l'action la plus importante
            // de l'app — seul le glissement vers le bas s'en sortait, et rien
            // ne l'annonçait.
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(t("sheet_close"))
                Spacer()
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up").font(.title3)
                }
                .accessibilityLabel(t("report_share"))
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial)

            QuickLook(url: url)
        }
    }
}

/// Lecteur natif d'iOS : la fiche s'AFFICHE tout de suite.
///
/// La feuille de partage seule obligeait à enregistrer dans Fichiers puis à
/// rouvrir depuis le gestionnaire de fichiers, qui la confiait à un navigateur —
/// trois étapes et une sortie de l'app pour voir ce qu'on vient de payer.
private struct QuickLook: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        return preview
    }
    func updateUIViewController(_ vc: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
