//
//  QRCodeGenerator.swift
//  arvos
//
//  Simple QR code generation using CoreImage
//

import UIKit
import CoreImage.CIFilterBuiltins

struct QRCodeGenerator {
    /// Generate a QR code image from a string
    static func generate(from string: String, size: CGSize = CGSize(width: 200, height: 200)) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()

        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"  // Medium error correction

        guard let qrCodeImage = filter.outputImage else {
            return nil
        }

        // Scale the QR code to the desired size
        let scaleX = size.width / qrCodeImage.extent.width
        let scaleY = size.height / qrCodeImage.extent.height
        let transformedImage = qrCodeImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        guard let cgImage = context.createCGImage(transformedImage, from: transformedImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    /// Generate QR code for WebSocket connection
    static func generateForWebSocket(ip: String, port: Int = 8765) -> UIImage? {
        let urlString = "ws://\(ip):\(port)"
        return generate(from: urlString)
    }
}
