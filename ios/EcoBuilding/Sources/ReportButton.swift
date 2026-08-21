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
    @State private var offer: API.MobileOffer?
    @State private var elapsed = 0
    @State private var pdf: URL?
    @State private var timer: Timer?

    enum Phase: Equatable {
        case idle, running, quota(String), failed
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

            switch phase {
            case let .quota(message):
                Text(message).font(.footnote).foregroundStyle(.orange)
            case .failed:
                Text("La fiche n'a pas pu être générée. Réessayez.")
                    .font(.footnote).foregroundStyle(.orange)
            default:
                if let offer {
                    Text("\(offer.free_reports) fiches offertes, puis "
                         + String(format: "%.2f", offer.unit_eur).replacingOccurrences(of: ".", with: ",")
                         + " € l'unité.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .task { offer = try? await API.offer() }
        .sheet(item: $pdf) { url in ShareSheet(url: url) }
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
            } catch is API.QuotaExhausted {
                // Jamais d'erreur technique sur un mur payant : on dit ce qui se
                // passe et ce que ça coûte.
                let o = offer
                phase = .quota(o.map { off in
                    "Vos \(off.free_reports) fiches offertes sont utilisées. "
                    + "Fiche à l'unité : "
                    + String(format: "%.2f", off.unit_eur).replacingOccurrences(of: ".", with: ",")
                    + " €."
                } ?? "Quota atteint.")
            } catch {
                phase = .failed
            }
        }
    }
}

/// Partage système : enregistrer dans Fichiers, envoyer par message, imprimer.
/// C'est ce qui fait de la fiche un objet transmissible — un agent l'envoie à
/// son client, un particulier à son artisan.
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
