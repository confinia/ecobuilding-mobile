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
    @State private var phase: Phase = .idle
    @State private var elapsed = 0
    @State private var pdf: URL?
    @State private var timer: Timer?

    enum Phase: Equatable {
        case idle, running, failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: download) {
                HStack(spacing: 10) {
                    Image(systemName: phase == .running
                          ? "arrow.triangle.2.circlepath" : "doc.text.fill")
                    Text(phase == .running ? stageLabel : "Obtenir la fiche PDF")
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

            // BÊTA : aucun message de quota ni de prix. Les premiers testeurs
            // sont des partenaires du métier, pas des clients — leur retour vaut
            // plus que la vente, et un mur tarifaire en pleine démonstration
            // devant un client serait un blocage inacceptable. Le mur payant
            // reviendra avec StoreKit, une fois les retours recueillis.
            if phase == .failed {
                Text("La fiche n'a pas pu être générée. Réessayez.")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .sheet(item: $pdf) { url in PDFPreview(url: url) }
    }

    private var stageLabel: String {
        // Étapes calées sur les durées réelles observées côté serveur.
        switch elapsed {
        case ..<3: return "Collecte des données…"
        case 3..<12: return "Rendu de la carte 3D…"
        default: return "Mise en page…"
        }
    }

    private func download() {
        guard let id = model.buildingID else { return }
        phase = .running
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in elapsed += 1 }
        }
        Task {
            defer { timer?.invalidate() }
            do {
                let url = try await API.report(buildingID: id, lon: model.lon, lat: model.lat)
                phase = .idle
                pdf = url                       // ouvre le partage système
            } catch {
                phase = .failed
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
private struct PDFPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let preview = QLPreviewController()
        preview.dataSource = context.coordinator
        // Bouton de fermeture explicite : sans lui, il fallait deviner qu'on
        // sort en glissant du haut vers le bas.
        preview.navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Fermer", style: .done,
            target: context.coordinator, action: #selector(Coordinator.close))
        let nav = UINavigationController(rootViewController: preview)
        context.coordinator.nav = nav
        return nav
    }
    func updateUIViewController(_ vc: UINavigationController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        weak var nav: UINavigationController?
        init(url: URL) { self.url = url }

        @objc func close() { nav?.dismiss(animated: true) }
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
