//  OpenNOW
//
//  Created by OpenAI on 7/6/26.
//

import Foundation

enum OpenNOWInterfacePreferences {
    static let controllerModeEnabledKey = "OpenNOW.Interface.ControllerModeEnabled"

    static var controllerModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: controllerModeEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: controllerModeEnabledKey) }
    }
}
