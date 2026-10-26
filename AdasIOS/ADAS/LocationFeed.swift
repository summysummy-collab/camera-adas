// LocationFeed.swift — GPS 定位喂给 EgoSpeed（时钟与视觉帧统一用 systemUptime 秒）
import Foundation
import CoreLocation

final class LocationFeed: NSObject, CLLocationManagerDelegate {
    private let lm = CLLocationManager()
    let ego = EgoSpeed()

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        lm.activityType = .automotiveNavigation
    }

    func request() {
        lm.requestWhenInUseAuthorization()
        lm.startUpdatingLocation()
    }

    func stop() { lm.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for loc in locations where loc.horizontalAccuracy > 0 {
            // 与 CACurrentMediaTime() 同源（都是 host time 基准的秒）
            let t = ProcessInfo.processInfo.systemUptime
            ego.push(t, lat: loc.coordinate.latitude, lon: loc.coordinate.longitude,
                     speed: loc.speed >= 0 ? loc.speed : nil,
                     accuracy: Double(loc.horizontalAccuracy))
        }
    }
}
