//
//  ServerStatusView.swift
//  arvos
//
//  Displays server connection info with QR code (Foxglove-style)
//

import SwiftUI

struct ServerStatusView: View {
    let ipAddresses: [String]
    let connectedClients: Int

    // Cache the QR code to avoid regenerating on every render
    @State private var qrImage: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            // QR Code - cached for performance
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .background(Color.white)
                    .cornerRadius(6)
            }

            // Info
            VStack(alignment: .leading, spacing: 6) {
                // Connection status
                HStack(spacing: 4) {
                    Circle()
                        .fill(connectedClients > 0 ? Theme.success : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                    Text("\(connectedClients)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // IP Address
                if let primaryIP = ipAddresses.first(where: { $0.hasPrefix("192.168") || $0.hasPrefix("10.") }) ?? ipAddresses.first {
                    Text(primaryIP)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()
        }
        .onAppear {
            generateQRCode()
        }
        .onChange(of: ipAddresses) { _ in
            generateQRCode()
        }
    }

    private func generateQRCode() {
        if let firstIP = ipAddresses.first {
            qrImage = QRCodeGenerator.generateForWebSocket(ip: firstIP)
        }
    }
}

#Preview {
    ServerStatusView(
        ipAddresses: ["192.168.1.100", "10.0.0.50"],
        connectedClients: 1
    )
    .padding()
    .background(Color(.systemBackground))
}
