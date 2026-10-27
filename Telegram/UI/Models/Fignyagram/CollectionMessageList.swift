import SwiftUI
import UIKit
import TDLibKit

/// UIKit-backed message list. SwiftUI's ScrollView + LazyVStack re-evaluates
/// row bodies and layout on every store change, which is the main reason long
/// chats stutter; UICollectionView virtualises cells and keeps scroll offsets
/// stable. Rows themselves stay SwiftUI (hosted per cell) so all message
/// features keep working.
struct CollectionMessageList: UIViewRepresentable {
    struct Entry: Identifiable, Equatable {
        enum Kind: Equatable { case day(TimeInterval), message(TDLibKit.Message) }
        let id: String
        let kind: Kind
    }

    let entries: [Entry]
    let scrollTarget: Int64?
    let onScrollTargetHandled: () -> Void
    let onReachTop: () -> Void
    let makeRow: (TDLibKit.Message) -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UICollectionView {
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                               heightDimension: .estimated(120)))
            let group = NSCollectionLayoutGroup.vertical(
                layoutSize: .init(widthDimension: .fractionalWidth(1),
                                  heightDimension: .estimated(120)),
                subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
            section.interGroupSpacing = 4
            return section
        }
        let collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = .clear
        collection.keyboardDismissMode = .interactive
        collection.alwaysBounceVertical = true
        collection.showsVerticalScrollIndicator = true
        collection.register(HostingMessageCell.self, forCellWithReuseIdentifier: HostingMessageCell.reuseID)
        collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "plainCell")
        collection.delegate = context.coordinator
        context.coordinator.attach(collection)
        return collection
    }

    func updateUIView(_ collection: UICollectionView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(entries: entries, animated: false)
        if let target = scrollTarget {
            context.coordinator.scroll(to: target) { onScrollTargetHandled() }
        }
    }

    static func dismantleUIView(_ uiView: UICollectionView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: CollectionMessageList
        private weak var collection: UICollectionView?
        private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
        private var entriesByID: [String: Entry] = [:]
        private var messageByID: [Int64: TDLibKit.Message] = [:]
        private var didInitialScroll = false
        private var lastCount = 0
        private var isLoadingOlder = false

        init(_ parent: CollectionMessageList) {
            self.parent = parent
            super.init()
        }

        func attach(_ collection: UICollectionView) {
            self.collection = collection
            dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collection) { [weak self] collection, indexPath, id in
                guard let self, let entry = self.entriesByID[id] else {
                    return UICollectionViewCell()
                }
                let content: AnyView
                switch entry.kind {
                case .day(let timestamp):
                    content = AnyView(DayHeaderView(timestamp: timestamp))
                case .message(let message):
                    content = self.parent.makeRow(message)
                }
                if #available(iOS 16.0, *) {
                    // UIHostingConfiguration sizes the cell from the SwiftUI
                    // view itself, which is what keeps heights correct.
                    let cell = collection.dequeueReusableCell(withReuseIdentifier: "plainCell", for: indexPath)
                    cell.contentConfiguration = UIHostingConfiguration {
                        content
                    }
                    .margins(.all, 0)
                    cell.backgroundColor = .clear
                    return cell
                }
                let cell = collection.dequeueReusableCell(withReuseIdentifier: HostingMessageCell.reuseID, for: indexPath) as! HostingMessageCell
                cell.set(rootView: content)
                return cell
            }
            collection.dataSource = dataSource
        }

        func detach() {
            collection?.delegate = nil
        }

        func apply(entries: [Entry], animated: Bool) {
            guard let collection else { return }
            var byID: [String: Entry] = [:]
            var messages: [Int64: TDLibKit.Message] = [:]
            for entry in entries {
                byID[entry.id] = entry
                if case .message(let message) = entry.kind { messages[message.id] = message }
            }
            entriesByID = byID
            messageByID = messages

            var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
            snapshot.appendSections([0])
            snapshot.appendItems(entries.map(\.id), toSection: 0)
            let grew = entries.count > lastCount
            lastCount = entries.count
            dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
                guard let self, let collection = self.collection else { return }
                if !self.didInitialScroll, !entries.isEmpty {
                    self.didInitialScroll = true
                    self.scrollToBottom(collection, animated: false)
                } else if grew {
                    let offset = collection.contentOffset.y
                    let maxOffset = max(0, collection.contentSize.height - collection.bounds.height)
                    if maxOffset - offset < 120 {
                        self.scrollToBottom(collection, animated: false)
                    }
                }
            }
        }

        func scrollToBottom(_ collection: UICollectionView, animated: Bool) {
            collection.layoutIfNeeded()
            let height = collection.contentSize.height
            guard height > 0 else { return }
            let maxY = max(0, height - collection.bounds.height + collection.adjustedContentInset.bottom)
            collection.setContentOffset(CGPoint(x: 0, y: maxY), animated: animated)
        }

        func scroll(to messageId: Int64, completion: @escaping () -> Void) {
            guard let collection,
                  let id = entriesByID.first(where: { entry in
                      if case .message(let message) = entry.value.kind { return message.id == messageId }
                      return false
                  })?.key,
                  let indexPath = dataSource.indexPath(for: id) else {
                completion()
                return
            }
            collection.scrollToItem(at: indexPath, at: .centeredVertically, animated: true)
            completion()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isLoadingOlder, scrollView.contentOffset.y < 120, scrollView.contentSize.height > scrollView.bounds.height else { return }
            isLoadingOlder = true
            parent.onReachTop()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.isLoadingOlder = false
            }
        }
    }
}

final class HostingMessageCell: UICollectionViewCell {
    static let reuseID = "HostingMessageCell"
    private var hosting: UIHostingController<AnyView>?
    private var widthConstraint: NSLayoutConstraint?

    func set(rootView: AnyView) {
        if let hosting {
            hosting.rootView = rootView
        } else {
            let controller = UIHostingController(rootView: rootView)
            controller.view.backgroundColor = .clear
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(controller.view)
            NSLayoutConstraint.activate([
                controller.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                controller.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                controller.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                controller.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
            ])
            hosting = controller
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        hosting?.rootView = AnyView(EmptyView())
    }
}

private struct DayHeaderView: View {
    let timestamp: TimeInterval

    var body: some View {
        Text(Self.formatter.string(from: Date(timeIntervalSince1970: timestamp)))
            .font(.appCaption.bold())
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(.secondarySystemBackground)))
            .frame(maxWidth: .infinity)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.setLocalizedDateFormatFromTemplate("d MMMM yyyy")
        return formatter
    }()
}
