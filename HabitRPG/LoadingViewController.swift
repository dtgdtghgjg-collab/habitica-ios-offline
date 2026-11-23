//
//  LoadingViewController.swift
//  Habitica
//
//  Created by Phillip Thelen on 13.03.18.
//  Copyright © 2018 HabitRPG Inc. All rights reserved.
//

import Foundation
import Habitica_Models
import ReactiveSwift
import SwiftUI

private class LoadingViewModel: ObservableObject {
    @Published var showProgress = false
}

struct LoadingPage: View {
    @ObservedObject fileprivate var viewModel: LoadingViewModel
    
    var body: some View {
        GeometryReader { reader in
        ZStack(alignment: .top) {
            Image(uiImage: Asset.confettiTiled.image).resizable(resizingMode: .tile).foregroundStyle(Color(hexadecimal: "CC62FA")).frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 24) {
                    Image(uiImage: Asset.launchLogo.image)
                    ZStack {
                        Circle().fill().foregroundStyle(Color(hexadecimal: "4F2A93").opacity(0.3))
                        ProgressView().habiticaProgressStyle().padding(12)
                    }.frame(width: 56, height: 56).opacity(viewModel.showProgress ? 1.0 : 0.0)
                }
                .padding(.top, (reader.size.height / 2 - 100) * 0.685)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hexadecimal: "7639ED"))
        .ignoresSafeArea()
    }
}

class LoadingViewController: UIHostingController<LoadingPage> {
    
    var loadingFinishedAction: (() async -> Void)?
    
    @IBOutlet weak var logoView: UIImageView!
    
    private var userRepository: UserRepository?
    private var configRepository = ConfigRepository.shared
    private let disposable = CompositeDisposable()
    private let viewModel = LoadingViewModel()
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder, rootView: LoadingPage(viewModel: viewModel))
    }
    
    private var wasDismissed = false
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Fully offline: no server user to fetch, the local player already
        // exists in Realm. Loading goes straight to the main screen.
    }
    
    override func viewDidAppear(_ animated: Bool) {
        if let delegate = UIApplication.shared.delegate as? HabiticaAppDelegate {
            if delegate.handleMaintenanceScreen() {
                return
            }
        }
        // Fully offline: always go to the main screen, never to login.
        segueForLoggedInUser()
        super.viewDidAppear(animated)
    }
    
    private func completeInitialLaunch() {
        // Fully offline: intro slides lead straight to the main screen,
        // never to a login screen.
        DispatchQueue.main.async {
            self.segueForLoggedInUser()
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        if let action = loadingFinishedAction {
            Task.detached {
                await action()
            }
        }
        if let targetUrl = ProcessInfo.processInfo.environment["TARGET_URL"] {
            RouterHandler.shared.handle(urlString: targetUrl)
        }
        if !disposable.isDisposed {
            disposable.dispose()
        }
        if !wasDismissed {
            wasDismissed = true
        }
        super.viewDidDisappear(animated)
    }
    
    private func segueForLoggedInUser() {
        if UserDefaults.standard.bool(forKey: "isInSetup") {
            perform(segue: StoryboardSegue.Intro.setupSegue)
        } else {
            perform(segue: StoryboardSegue.Intro.initialSegue)
        }
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        // Fully offline: no login segue to prepare for.
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
}
