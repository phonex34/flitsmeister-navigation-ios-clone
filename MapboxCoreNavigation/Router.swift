import Foundation
import CoreLocation
import MapboxDirections

/**
 A router data source, also known as a location manager, supplies location data to a `Router` instance. For example, a `MapboxNavigationService` supplies location data to a `RouteController` or `LegacyRouteController`.
 */
public protocol RouterDataSource: class {
    /**
     The location provider for the `Router.` This class is designated as the object that will provide location updates when requested.
     */
    var locationProvider: NavigationLocationManager.Type { get }
}

/**
 A class conforming to the `Router` protocol tracks the user’s progress as they travel along a predetermined route. It calls methods on its `delegate`, which conforms to the `RouterDelegate` protocol, whenever significant events or decision points occur along the route. Despite its name, this protocol does not define the interface of a routing engine.
 
 There are two concrete implementations of the `Router` protocol. `RouteController`, the default implementation, is capable of client-side routing and depends on the Mapbox Navigation Native framework. `LegacyRouteController` is an alternative implementation that does not have this dependency but must be used in conjunction with the Mapbox Directions API over a network connection.
 */
public protocol Router: class, CLLocationManagerDelegate {
    /**
     The route controller’s associated location manager.
     */
    var dataSource: RouterDataSource { get }
    
    /**
     The route controller’s delegate.
     */
    var delegate: RouterDelegate? { get set }
    
    /**
     Intializes a new `RouteController`.
     
     - parameter route: The route to follow.
     - parameter directions: The Directions object that created `route`.
     - parameter source: The data source for the RouteController.
     */
    init(along route: Route, directions: Directions, dataSource source: RouterDataSource)
    
    /**
     Details about the user’s progress along the current route, leg, and step.
     */
    var routeProgress: RouteProgress { get }
    
    var route: Route { get set }
    
    /**
     Given a users current location, returns a Boolean whether they are currently on the route.
     
     If the user is not on the route, they should be rerouted.
     */
    func userIsOnRoute(_ location: CLLocation) -> Bool
    func reroute(from: CLLocation, along: RouteProgress)
    
    /**
     The idealized user location. Snapped to the route line, if applicable, otherwise raw or nil.
     */
    var location: CLLocation? { get }
    
    /**
     The most recently received user location.
     - note: This is a raw location received from `locationManager`. To obtain an idealized location, use the `location` property.
     */
    var rawLocation: CLLocation? { get }
    
    /**
     If true, the `RouteController` attempts to calculate a more optimal route for the user on an interval defined by `RouteControllerProactiveReroutingInterval`.
     */
    var reroutesProactively: Bool { get set }
    
    /**
     Advances the leg index.
     
     This is a convienence method provided to advance the leg index of any given router without having to worry about the internal data structure of the router.
     */
    func advanceLegIndex(location: CLLocation)
    
    func enableLocationRecording()
    func disableLocationRecording()
    func locationHistory() -> String?
}

protocol InternalRouter: class {
    var lastProactiveRerouteDate: Date? { get set }
    
    var routeTask: URLSessionDataTask? { get set }
    
    var didFindFasterRoute: Bool { get set }
    
    var lastRerouteLocation: CLLocation? { get set }
    
    func setRoute(route: Route, proactive: Bool)
    
    var isRerouting: Bool { get set }
    
    var directions: Directions { get }
    
    var routeProgress: RouteProgress { get set }
}

extension InternalRouter where Self: Router {
    func checkForFasterRoute(from location: CLLocation, routeProgress: RouteProgress) {
        // Check for faster route given users current location
        guard reroutesProactively else { return }
        
        // Only check for faster alternatives if the user has plenty of time left on the route.
        guard routeProgress.durationRemaining > RouteControllerMinimumDurationRemainingForProactiveRerouting else { return }
        // If the user is approaching a maneuver, don't check for a faster alternatives
        guard routeProgress.currentLegProgress.currentStepProgress.durationRemaining > RouteControllerMediumAlertInterval else { return }
        
        guard let currentUpcomingManeuver = routeProgress.currentLegProgress.upcomingStep else {
            return
        }
        
        guard let lastProactiveRerouteDate = lastProactiveRerouteDate else {
            self.lastProactiveRerouteDate = location.timestamp
            return
        }
        
        // Only check every so often for a faster route.
        guard location.timestamp.timeIntervalSince(lastProactiveRerouteDate) >= RouteControllerProactiveReroutingInterval else {
            return
        }
        
        let durationRemaining = routeProgress.durationRemaining
        
        // Avoid interrupting an ongoing reroute
        if isRerouting { return }
        isRerouting = true
        
        getDirections(from: location, along: routeProgress) { [weak self] (route, error) in
            self?.isRerouting = false
            
            guard let route = route else { return }
            
            self?.lastProactiveRerouteDate = nil
            
            guard let firstLeg = route.legs.first, let firstStep = firstLeg.steps.first else {
                return
            }
            
            let routeIsFaster = firstStep.expectedTravelTime >= RouteControllerMediumAlertInterval &&
                currentUpcomingManeuver == firstLeg.steps[1] && route.expectedTravelTime <= 0.9 * durationRemaining
            
            if routeIsFaster {
                self?.setRoute(route: route, proactive: true)
            }
        }
    }
    
    func getDirections(from location: CLLocation, along progress: RouteProgress, completion: @escaping (_ route: Route?, _ error: Error?)->Void) {
        routeTask?.cancel()
        let options = progress.reroutingOptions(with: location)
        
        lastRerouteLocation = location
        
        routeTask = directions.calculate(options) {(waypoints, routes, error) in
            guard let routes = routes else {
                return completion(nil, error)
            }
            
            let mostSimilar = routes.mostSimilar(to: progress.route)
            return completion(mostSimilar ?? routes.first, error)
        }
    }
    
    func setRoute(route: Route, proactive: Bool) {
        let spokenInstructionIndex = routeProgress.currentLegProgress.currentStepProgress.spokenInstructionIndex
        
        if proactive {
            didFindFasterRoute = true
        }
        defer {
            didFindFasterRoute = false
        }
        
        routeProgress = RouteProgress(route: route, legIndex: 0, spokenInstructionIndex: spokenInstructionIndex)
    }
    
    func announce(reroute newRoute: Route, at location: CLLocation?, proactive: Bool) {
        var userInfo = [RouteController.NotificationUserInfoKey: Any]()
        if let location = location {
            userInfo[.locationKey] = location
        }
        userInfo[.isProactiveKey] = proactive
        NotificationCenter.default.post(name: .routeControllerDidReroute, object: self, userInfo: userInfo)
        delegate?.router(self, didRerouteAlong: routeProgress.route, at: location, proactive: proactive)
    }
}

extension Array where Element: MapboxDirections.Route {
    func mostSimilar(to route: Route) -> Route? {
        let target = route.description
        return self.min { (left, right) -> Bool in
            let leftDistance = left.description.minimumEditDistance(to: target)
            let rightDistance = right.description.minimumEditDistance(to: target)
            return leftDistance < rightDistance
        }
    }
}
