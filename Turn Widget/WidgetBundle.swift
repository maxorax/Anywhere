//
//  WidgetBundle.swift
//  Turn
//
//  Created by NodePassProject on 4/6/26.
//

import WidgetKit
import SwiftUI

@main
struct TurnWidgetBundle: WidgetBundle {
    var body: some Widget {
        VPNToggleControl()
        ModeToggleControl()
    }
}
