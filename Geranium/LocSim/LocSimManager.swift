//
//  LocSimManager.swift
//  Geranium
//
//  Created by Constantin Clerc on 12.11.2022.
//

import Foundation
import CoreLocation


class LocSimManager {
    static let simManager = CLSimulationManager()
    
    /// Updates timezone
    static func post_required_timezone_update(){
        CFNotificationCenterPostNotificationWithOptions(CFNotificationCenterGetDarwinNotifyCenter(), .init("AutomaticTimeZoneUpdateNeeded" as CFString), nil, nil, kCFNotificationDeliverImmediately);
    }
    
    /// Starts a location simulation of specified argument "location"
    // TODO: save
    static func startLocSim(location: CLLocation) {
        simManager.stopLocationSimulation()
        simManager.clearSimulatedLocations()
        simManager.appendSimulatedLocation(location)
        simManager.flush()
        simManager.startLocationSimulation()
        post_required_timezone_update();
    }
    
    /// Stops location simulation
    static func stopLocSim(){
        simManager.stopLocationSimulation()
        simManager.clearSimulatedLocations()
        simManager.flush()
        post_required_timezone_update();
    }
}


struct EquatableCoordinate: Equatable {
    var coordinate: CLLocationCoordinate2D
    
    static func ==(lhs: EquatableCoordinate, rhs: EquatableCoordinate) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude
    }
}


// https://stackoverflow.com/a/75703059

class LocationModel: NSObject, ObservableObject {
    private let locationManager = CLLocationManager()
    @Published var authorisationStatus: CLAuthorizationStatus = .notDetermined
    @Published var currentLocation: CLLocation?

    override init() {
        super.init()
        self.locationManager.delegate = self
        self.locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    public func requestAuthorisation(always: Bool = false) {
        if always {
            self.locationManager.requestAlwaysAuthorization()
        } else {
            self.locationManager.requestWhenInUseAuthorization()
        }
        locationManager.startUpdatingLocation()
    }
    
    /// 强制刷新位置，清除缓存并重新获取真实位置
    public func forceRefreshLocation() {
        // 先停止位置更新
        locationManager.stopUpdatingLocation()
        // 立即清除缓存的位置（在主线程）
        DispatchQueue.main.async {
            self.currentLocation = nil
        }
        // 重新启动位置更新，强制获取新的真实位置
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            // 重新启动位置更新
            self.locationManager.startUpdatingLocation()
            // 如果已经有授权，立即请求一次位置更新
            if self.authorisationStatus == .authorizedWhenInUse || self.authorisationStatus == .authorizedAlways {
                self.locationManager.requestLocation()
            }
        }
    }
}

extension LocationModel: CLLocationManagerDelegate {

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        self.authorisationStatus = status
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.startUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        DispatchQueue.main.async {
            self.currentLocation = location
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 处理定位错误
        print("Location error: \(error.localizedDescription)")
    }
}
