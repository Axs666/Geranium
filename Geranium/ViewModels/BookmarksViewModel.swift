//
//  BookmarksViewModel.swift
//  Geranium
//
//  Created by Codex on 22.05.2024.
//

import Foundation
import CoreLocation

@MainActor
final class BookmarksViewModel: ObservableObject {
    @Published var editorMode: BookmarkEditorMode?
    @Published var showImportPrompt: Bool = false
    @Published var importResultMessage: String?
    @Published var showImportResult: Bool = false

    private let store: BookmarkStore
    private unowned let mapViewModel: MapViewModel
    private let settings: LocSimSettings

    init(store: BookmarkStore, mapViewModel: MapViewModel, settings: LocSimSettings) {
        self.store = store
        self.mapViewModel = mapViewModel
        self.settings = settings
        evaluateLegacyState()
    }

    func evaluateLegacyState() {
        showImportPrompt = store.canImportLegacyRecords
    }

    func performLegacyImport() {
        do {
            let imported = try store.importLegacyBookmarks()
            importResultMessage = imported > 0 ?
            String(format: "成功导入 %d 条收藏。", imported) :
            "没有发现可导入的收藏。"
        } catch {
            importResultMessage = "导入失败，请重试。"
        }
        showImportResult = true
        showImportPrompt = false
    }

    func select(_ bookmark: Bookmark) {
        // 检查当前是否正在使用该收藏的定位
        let isCurrentlyActive = store.lastUsedBookmarkID == bookmark.id && mapViewModel.isSpoofingActive
        
        if isCurrentlyActive {
            // 如果当前已激活，则关闭定位
            mapViewModel.stopSpoofing()
        } else {
            // 否则，开启定位并切换到该位置（忽略自动启动设置，强制开启）
            mapViewModel.focus(on: bookmark, autoStartOverride: true)
        }
    }

    func deleteBookmarks(at offsets: IndexSet) {
        store.deleteBookmarks(at: offsets)
    }

    func delete(_ bookmark: Bookmark) {
        if let index = store.bookmarks.firstIndex(of: bookmark) {
            store.deleteBookmarks(at: IndexSet(integer: index))
        }
    }

    func moveBookmarks(from source: IndexSet, to destination: Int) {
        store.moveBookmarks(from: source, to: destination)
    }

    func addBookmark() {
        editorMode = .create(nil)
    }

    func edit(_ bookmark: Bookmark) {
        editorMode = .edit(bookmark)
    }

    func dismissEditor() {
        editorMode = nil
    }

    func saveBookmark(name: String, coordinate: CLLocationCoordinate2D, note: String?) {
        guard let editorMode else { return }
        switch editorMode {
        case .create:
            store.addBookmark(name: name, coordinate: coordinate, note: note)
        case .edit(let bookmark):
            var updated = bookmark
            updated.name = name
            updated.coordinate = coordinate
            updated.note = note
            store.updateBookmark(updated)
        }
        self.editorMode = nil
    }
}
