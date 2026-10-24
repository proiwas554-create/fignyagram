import SwiftUI
import UIKit

/// Lightweight image editor used before sending photos: center crop to common
/// aspect ratios, rotation and a freehand marker for redaction/notes.
struct PhotoEditorView: View {
    let original: UIImage
    let onDone: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage
    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke?
    @State private var color: Color = .red
    @State private var lineWidth: CGFloat = 0.018
    @State private var isCropping = false
    @State private var cropStart: CGPoint?
    @State private var cropRect: CGRect?

    init(image: UIImage, onDone: @escaping (UIImage) -> Void) {
        self.original = image
        self.onDone = onDone
        _image = State(initialValue: image)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let imageRect = aspectFitRect(image.size, in: geometry.size)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                        ZStack {
                            Canvas { context, _ in
                                for stroke in strokes {
                                    draw(stroke, in: context, imageRect: imageRect)
                                }
                                if let currentStroke {
                                    draw(currentStroke, in: context, imageRect: imageRect)
                                }
                            }
                            if let cropRect {
                                let viewRect = CGRect(
                                    x: imageRect.minX + cropRect.minX * imageRect.width,
                                    y: imageRect.minY + cropRect.minY * imageRect.height,
                                    width: cropRect.width * imageRect.width,
                                    height: cropRect.height * imageRect.height
                                )
                                Path { path in
                                    path.addRect(CGRect(origin: .zero, size: geometry.size))
                                    path.addRect(viewRect)
                                }
                                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                                .allowsHitTesting(false)
                                Rectangle()
                                    .stroke(Color.white, lineWidth: 1.5)
                                    .frame(width: viewRect.width, height: viewRect.height)
                                    .position(x: viewRect.midX, y: viewRect.midY)
                                    .allowsHitTesting(false)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    guard imageRect.contains(value.location) else { return }
                                    let point = normalize(value.location, in: imageRect)
                                    if isCropping {
                                        if cropStart == nil { cropStart = point }
                                        guard let start = cropStart else { return }
                                        cropRect = CGRect(
                                            x: min(start.x, point.x),
                                            y: min(start.y, point.y),
                                            width: abs(point.x - start.x),
                                            height: abs(point.y - start.y)
                                        )
                                    } else {
                                        if currentStroke == nil {
                                            currentStroke = Stroke(color: color, width: lineWidth, points: [point])
                                        } else {
                                            currentStroke?.points.append(point)
                                        }
                                    }
                                }
                                .onEnded { _ in
                                    if isCropping {
                                        cropStart = nil
                                    } else {
                                        if let currentStroke {
                                            strokes.append(currentStroke)
                                        }
                                        currentStroke = nil
                                    }
                                }
                        )
                    }
                }
                .background(Color.black)

                controls
            }
            .background(Color.black)
            .navigationTitle("Редактор")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        onDone(render())
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ForEach(brushColors, id: \.self) { item in
                    Button {
                        color = item
                    } label: {
                        Circle()
                            .fill(item)
                            .frame(width: 26, height: 26)
                            .overlay(
                                Circle().stroke(
                                    color == item ? Color.white : Color.white.opacity(0.25),
                                    lineWidth: color == item ? 2 : 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    if !strokes.isEmpty { strokes.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(strokes.isEmpty)

                Button {
                    strokes.removeAll()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(strokes.isEmpty)
            }
            .font(.system(size: 18))
            .foregroundColor(.white)
            .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Image(systemName: "paintbrush.fill")
                    .font(.appFootnote)
                Slider(value: $lineWidth, in: 0.004...0.06)
            }
            .foregroundColor(.white)
            .padding(.horizontal, 16)

            HStack(spacing: 12) {
                Button {
                    isCropping.toggle()
                    if isCropping {
                        cropRect = nil
                        cropStart = nil
                    }
                } label: {
                    Label(isCropping ? "Обрезка…" : "Свободная", systemImage: "crop.rotate")
                        .font(.appFootnote)
                }
                .buttonStyle(.bordered)
                .tint(.white)

                if isCropping {
                    Button("Применить") {
                        applyFreeCrop()
                    }
                    .font(.appFootnote)
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .foregroundColor(.white)
                    .disabled((cropRect?.width ?? 0) < 0.02 || (cropRect?.height ?? 0) < 0.02)
                }

                Menu {
                    Button("1:1") { crop(aspect: 1) }
                    Button("4:3") { crop(aspect: 4.0 / 3.0) }
                    Button("3:4") { crop(aspect: 3.0 / 4.0) }
                    Button("16:9") { crop(aspect: 16.0 / 9.0) }
                } label: {
                    Label("Обрезать", systemImage: "crop")
                        .font(.appFootnote)
                }

                Button {
                    rotate()
                } label: {
                    Label("Повернуть", systemImage: "rotate.right")
                        .font(.appFootnote)
                }

                Spacer()

                Text("Маркер")
                    .font(.appCaption2)
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.bordered)
            .tint(.white)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .padding(.top, 10)
        .background(Color.black)
    }

    private var brushColors: [Color] {
        [.red, .black, .yellow, .white, .blue]
    }

    private struct Stroke {
        let color: Color
        let width: CGFloat
        var points: [CGPoint]
    }

    private func draw(_ stroke: Stroke, in context: GraphicsContext, imageRect: CGRect) {
        guard stroke.points.count > 1 else { return }
        var path = Path()
        path.move(to: denormalize(stroke.points[0], in: imageRect))
        for point in stroke.points.dropFirst() {
            path.addLine(to: denormalize(point, in: imageRect))
        }
        context.stroke(
            path,
            with: .color(stroke.color),
            style: StrokeStyle(
                lineWidth: max(2, stroke.width * min(imageRect.width, imageRect.height)),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func aspectFitRect(_ imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func render() -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            for stroke in strokes {
                guard stroke.points.count > 1 else { continue }
                let path = UIBezierPath()
                let first = denormalize(stroke.points[0], in: CGRect(origin: .zero, size: size))
                path.move(to: first)
                for point in stroke.points.dropFirst() {
                    path.addLine(to: denormalize(point, in: CGRect(origin: .zero, size: size)))
                }
                UIColor(stroke.color).setStroke()
                path.lineWidth = max(2, stroke.width * min(size.width, size.height))
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.stroke()
            }
        }
    }

    private func applyFreeCrop() {
        guard let cropRect, cropRect.width > 0.01, cropRect.height > 0.01 else { return }
        let size = image.size
        let rect = CGRect(
            x: cropRect.minX * size.width,
            y: cropRect.minY * size.height,
            width: cropRect.width * size.width,
            height: cropRect.height * size.height
        )
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        image = renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
        strokes.removeAll()
        isCropping = false
        self.cropRect = nil
        cropStart = nil
    }

    private func crop(aspect: CGFloat) {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return }
        var cropSize = size
        if size.width / size.height > aspect {
            cropSize.width = size.height * aspect
        } else {
            cropSize.height = size.width / aspect
        }
        let origin = CGPoint(x: (size.width - cropSize.width) / 2, y: (size.height - cropSize.height) / 2)
        let rect = CGRect(origin: origin, size: cropSize)
        let renderer = UIGraphicsImageRenderer(size: cropSize)
        image = renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.minX, y: -rect.minY))
        }
        strokes.removeAll()
    }

    private func rotate() {
        let size = image.size
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size.height, height: size.width))
        image = renderer.image { context in
            context.cgContext.translateBy(x: size.height / 2, y: size.width / 2)
            context.cgContext.rotate(by: .pi / 2)
            image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
        strokes.removeAll()
    }
}
