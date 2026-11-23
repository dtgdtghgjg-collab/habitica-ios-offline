//
//  GuidelinesViewController.swift
//  Habitica
//
//  Created by Phillip Thelen on 23.02.18.
//  Copyright © 2018 HabitRPG Inc. All rights reserved.
//

import UIKit
import Down
import SwiftUIX

class GuidelinesViewController: BaseUIViewController {
    @IBOutlet weak var textView: UITextView!
    let activityIndicator = UIHostingView(rootView: HabiticaProgressView())

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.addSubview(activityIndicator)
        
        navigationItem.title = L10n.Titles.guidelines
        textView.isEditable = false
        
        // Fully offline: guidelines are not fetched from the server.
        textView.text = L10n.Titles.guidelines
        textView.isHidden = false
        activityIndicator.isHidden = true
    }
    
    override func applyTheme(theme: any Theme) {
        super.applyTheme(theme: theme)
        textView.backgroundColor = theme.contentBackgroundColor
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        activityIndicator.pin.center().size(44)
    }
    
    @IBAction func doneButtonTapped(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }
}
