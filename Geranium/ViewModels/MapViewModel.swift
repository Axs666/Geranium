//
//  MapViewModel.swift
//  Geranium
//
//  Created by Codex on 22.05.2024.
//

import Foundation
import MapKit
import Combine
import SwiftUI

@MainActor
final class MapViewModel: ObservableObject {
    @Published var selectedLocation: LocationPoint?
    @Published var mapRegion: MKCoordinateRegion
    @Published var editorMode: BookmarkEditorMode?
    @Published var errorMessage: String?
    @Published var showErrorAlert: Bool = false
    @Published var lastMapCenter: CLLocationCoordinate2D?
    @Published var searchText: String = ""
    @Published var searchResults: [SearchResult] = []
    @Published var isSearching: Bool = false
    @Published var showSearchResults: Bool = false

    var statusInfo: MapStatus {
        if let active = engine.session.activePoint {
            return MapStatus(
                title: "定位模拟已开启",
                detail: active.label ?? active.coordinateDescription,
                isActive: true
            )
        }

        return MapStatus(
            title: "定位模拟已关闭",
            detail: "点击地图即可放置定位点",
            isActive: false
        )
    }

    var primaryButtonTitle: String {
        engine.session.isActive ? "停止模拟" : "开始模拟"
    }

    var primaryButtonDisabled: Bool {
        if engine.session.isActive { return false }
        return selectedLocation == nil
    }

    var activeLocation: LocationPoint? {
        engine.session.activePoint
    }
    
    var isSpoofingActive: Bool {
        engine.session.isActive
    }
    
    var realLocation: CLLocationCoordinate2D? {
        locationAuthorizer.currentLocation?.coordinate
    }

    private let engine: LocationSpoofingEngine
    private let settings: LocSimSettings
    private unowned let bookmarkStore: BookmarkStore
    private var cancellables = Set<AnyCancellable>()
    private let locationAuthorizer = LocationModel()
    private var hasCenteredOnUser = false
    private var searchTask: Task<Void, Never>?
    private var realLocationSubscription: AnyCancellable?

    init(engine: LocationSpoofingEngine, settings: LocSimSettings, bookmarkStore: BookmarkStore) {
        self.engine = engine
        self.settings = settings
        self.bookmarkStore = bookmarkStore

        let defaultCenter = CLLocationCoordinate2D(latitude: 39.9042, longitude: 116.4074)
        self.mapRegion = MKCoordinateRegion(center: defaultCenter,
                                            span: MKCoordinateSpan(latitudeDelta: settings.mapSpanDegrees,
                                                                   longitudeDelta: settings.mapSpanDegrees))

        engine.$session
            .receive(on: RunLoop.main)
            .sink { [weak self] session in
                guard let self else { return }
                if !session.isActive {
                    bookmarkStore.markAsLastUsed(nil)
                }
                objectWillChange.send()
            }
            .store(in: &cancellables)

        // 订阅位置更新，在首次获取到真实位置时自动居中（仅在未激活模拟时）
        locationAuthorizer.$currentLocation
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                guard let self else { return }
                // 只在未激活模拟定位且未居中过时才自动居中到真实位置
                if !hasCenteredOnUser && !engine.session.isActive {
                    hasCenteredOnUser = true
                    centerMap(on: location.coordinate)
                }
            }
            .store(in: &cancellables)
    }

    func requestLocationPermission() {
        locationAuthorizer.requestAuthorisation(always: true)
        
        // 如果模拟定位未激活，强制刷新并居中到真实位置
        if !engine.session.isActive {
            // 延迟一下，确保权限请求完成
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                if !self.engine.session.isActive {
                    // 强制刷新位置
                    self.locationAuthorizer.forceRefreshLocation()
                    // 等待获取真实位置后居中
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self else { return }
                        if !self.engine.session.isActive,
                           let realLocation = self.locationAuthorizer.currentLocation?.coordinate {
                            self.hasCenteredOnUser = true
                            self.centerMap(on: realLocation)
                        }
                    }
                }
            }
        }
    }

    func handleMapTap(_ coordinate: CLLocationCoordinate2D) {
        selectedLocation = LocationPoint(coordinate: coordinate, label: nil)
        if settings.autoCenterOnSelection {
            centerMap(on: coordinate)
        }
    }

    func updateMapCenter(_ coordinate: CLLocationCoordinate2D) {
        lastMapCenter = coordinate
    }

    func openBookmarkCreator() {
        if let selectedLocation {
            editorMode = .create(selectedLocation)
        } else if let center = lastMapCenter {
            editorMode = .create(LocationPoint(coordinate: center))
        } else {
            errorMessage = "请先在地图上选择一个位置"
            showErrorAlert = true
        }
    }

    func completeEditorFlow() {
        editorMode = nil
    }

    func toggleSpoofing() {
        if engine.session.isActive {
            stopSpoofing()
        } else {
            startSpoofingSelected()
        }
    }

    func startSpoofingSelected() {
        guard let selectedLocation else {
            engine.recordError(.invalidCoordinate)
            errorMessage = "请先在地图上选择一个有效的位置"
            showErrorAlert = true
            return
        }
        startSpoofing(point: selectedLocation, bookmark: nil)
    }

    func focus(on bookmark: Bookmark, autoStartOverride: Bool? = nil) {
        let point = bookmark.locationPoint
        selectedLocation = point
        centerMap(on: point.coordinate)

        let shouldAutoStart = autoStartOverride ?? settings.autoStartFromBookmarks
        if shouldAutoStart {
            startSpoofing(point: point, bookmark: bookmark)
        }
    }

    func stopSpoofing() {
        engine.stopSpoofing()
        bookmarkStore.markAsLastUsed(nil)
        
        // 停止模拟后，立即强制刷新真实位置
        // 清除缓存并重新获取真实位置
        locationAuthorizer.forceRefreshLocation()
        
        // 重置居中标志，允许重新居中到真实位置
        hasCenteredOnUser = false
    }

    func performSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            searchResults = []
            showSearchResults = false
            return
        }

        isSearching = true
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = query
            let search = MKLocalSearch(request: request)
            do {
                let response = try await search.start()
                let mapped = response.mapItems.map(SearchResult.init)
                await MainActor.run {
                    self.searchResults = mapped
                    self.showSearchResults = !mapped.isEmpty
                    self.isSearching = false
                }
            } catch {
                await MainActor.run {
                    self.isSearching = false
                }
            }
        }
    }

    func selectSearchResult(_ result: SearchResult) {
        let coordinate = result.mapItem.placemark.coordinate
        selectedLocation = LocationPoint(coordinate: coordinate, label: result.title, note: result.subtitle)
        centerMap(on: coordinate)
        showSearchResults = false
        searchResults = []
        searchText = result.title
    }

    func clearSearch() {
        searchText = ""
        searchResults = []
        showSearchResults = false
        isSearching = false
        searchTask?.cancel()
    }
    
    func centerOnRealLocation() {
        // 取消之前的订阅
        realLocationSubscription?.cancel()
        
        // 记录刷新时间，只接受刷新后的位置更新
        let refreshTime = Date()
        
        // 强制刷新位置，清除缓存并重新获取真实位置
        locationAuthorizer.forceRefreshLocation()
        
        // 创建一个订阅来等待新的真实位置更新（只接受刷新后的位置）
        realLocationSubscription = locationAuthorizer.$currentLocation
            .compactMap { $0 }
            .filter { location in
                // 只接受刷新后的位置（时间戳在刷新之后或接近当前时间）
                location.timestamp.timeIntervalSince(refreshTime) >= -1.0
            }
            .first()
            .receive(on: RunLoop.main)
            .sink { [weak self] location in
                guard let self else { return }
                self.centerMap(on: location.coordinate)
                self.realLocationSubscription?.cancel()
            }
        
        // 延迟检查：如果已经有了新的位置，直接使用
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            // 如果订阅还在，说明还没有获取到位置
            if self.realLocationSubscription != nil {
                if let location = self.locationAuthorizer.currentLocation,
                   location.timestamp.timeIntervalSince(refreshTime) >= -1.0 {
                    // 如果已经有了新的真实位置，直接使用
                    self.centerMap(on: location.coordinate)
                    self.realLocationSubscription?.cancel()
                } else {
                    // 5秒后如果没有位置，显示错误并取消订阅
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                        guard let self else { return }
                        self.realLocationSubscription?.cancel()
                        if self.locationAuthorizer.currentLocation == nil {
                            self.errorMessage = "无法获取真实位置，请检查定位权限设置"
                            self.showErrorAlert = true
                        }
                    }
                }
            }
        }
    }

    private func startSpoofing(point: LocationPoint, bookmark: Bookmark?) {
        engine.startSpoofing(point: point)
        if let bookmark {
            bookmarkStore.markAsLastUsed(bookmark)
        } else {
            bookmarkStore.markAsLastUsed(nil)
        }
    }

    private func centerMap(on coordinate: CLLocationCoordinate2D) {
        withAnimation(settings.dampedAnimations ? .spring(response: 0.45, dampingFraction: 0.75) : .default) {
            mapRegion = MKCoordinateRegion(center: coordinate, span: mapRegion.span)
        }
        lastMapCenter = coordinate
    }
}

struct MapStatus {
    var title: String
    var detail: String
    var isActive: Bool
}

struct SearchResult: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem

    init(mapItem: MKMapItem) {
        self.mapItem = mapItem
    }

    var title: String {
        mapItem.name ?? "未知地点"
    }

    var subtitle: String {
        mapItem.placemark.title ?? ""
    }
}
