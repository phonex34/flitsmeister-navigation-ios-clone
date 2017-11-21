import UIKit
import MapboxCoreNavigation
import MapboxDirections


/// :nodoc:
@IBDesignable
@objc(MBLanesContainerView)
public class LanesContainerView: LanesView {
    weak var stackView: UIStackView!
    weak var separatorView: SeparatorView!
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }
    
    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        commonInit()
    }
    
    func laneArrowView() -> LaneView {
        let view = LaneView(frame: CGRect(origin: .zero, size: CGSize(width: 30, height: 30)))
        view.backgroundColor = .clear
        return view
    }
    
    func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false
        
        let heightConstraint = heightAnchor.constraint(equalToConstant: 40)
        heightConstraint.priority = 999
        heightConstraint.isActive = true
        
        let stackView = UIStackView(arrangedSubviews: [])
        stackView.axis = .horizontal
        stackView.spacing = 4
        stackView.distribution = .equalCentering
        stackView.alignment = .center
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        self.stackView = stackView
        
        let separatorView = SeparatorView()
        separatorView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separatorView)
        self.separatorView = separatorView
        
        addConstraints(NSLayoutConstraint.constraints(withVisualFormat: "V:|-0-[stackView]-0-|", options: [], metrics: nil, views: ["stackView": stackView]))
        addConstraint(NSLayoutConstraint(item: self, attribute: .centerX, relatedBy: .equal, toItem: stackView, attribute: .centerX, multiplier: 1, constant: 0))
        
        separatorView.heightAnchor.constraint(equalToConstant: 2).isActive = true
        separatorView.leftAnchor.constraint(equalTo: leftAnchor).isActive = true
        separatorView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2).isActive = true
        separatorView.rightAnchor.constraint(equalTo: rightAnchor).isActive = true
    }
    
    func updateLaneViews(step: RouteStep, durationRemaining: TimeInterval) {
        clearLaneViews()
        
        if let allLanes = step.intersections?.first?.approachLanes,
            let usableLanes = step.intersections?.first?.usableApproachLanes,
            durationRemaining < RouteControllerMediumAlertInterval {
            
            for (i, lane) in allLanes.enumerated() {
                let laneView = laneArrowView()
                laneView.lane = lane
                laneView.maneuverDirection = step.maneuverDirection
                laneView.isValid = usableLanes.contains(i as Int)
                stackView.addArrangedSubview(laneView)
            }
        }
    }
    
    fileprivate func clearLaneViews() {
        stackView.arrangedSubviews.forEach {
            stackView.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }
}
