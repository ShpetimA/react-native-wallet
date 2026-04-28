import Foundation
import PassKit
import UIKit
import React

public typealias CompletionHandler = (OperationResult, NSDictionary?) -> Void

@objc public protocol WalletDelegate {
  func sendEvent(name: String, result: NSDictionary)
}

@objc
open class WalletManager: UIViewController {
  
  @objc public weak var delegate: WalletDelegate? = nil
  
  private var addPassViewController: PKAddPaymentPassViewController?

  private var presentAddPaymentPassCompletionHandler: (CompletionHandler)?
  
  private var addPaymentPassCompletionHandler: (CompletionHandler)?

  private var addPassHandler: ((PKAddPaymentPassRequest) -> Void)?
  
  @objc public var packageName = "react-native-wallet"
  
  let passLibrary = PKPassLibrary()

  override init(nibName: String?, bundle: Bundle?) {
    super.init(nibName: nibName, bundle: bundle)
    addPassObserver()
  }
  
  required public init?(coder: NSCoder) {
    super.init(coder: coder)
    addPassObserver()
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  func addPassObserver() {
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(passLibraryDidChange),
      name: NSNotification.Name(rawValue: PKPassLibraryNotificationName.PKPassLibraryDidChange.rawValue),
      object: passLibrary
    )
  }
  
  @objc func passLibraryDidChange(_ notification: Notification) {
    guard let userInfo = notification.userInfo else {
      return
    }
    
    // Check if passes were added or status changed
    if let addedPasses = userInfo[PKPassLibraryNotificationKey.addedPassesUserInfoKey] as? [PKPass] {
      checkPassActivationStatus(addedPasses)
    }
    
    // Check for updated passes
    if let replacedPasses = userInfo[PKPassLibraryNotificationKey.replacementPassesUserInfoKey] as? [PKPass] {
      checkPassActivationStatus(replacedPasses)
    }
  }
  
  func checkPassActivationStatus(_ passes: [PKPass]) {
    for pass in passes {
      if pass.secureElementPass?.passActivationState == .activated {
        delegate?.sendEvent(name: Event.onCardActivated.rawValue, result:  [
          "status": "activated",
          "tokenId": pass.serialNumber
        ]);
      }
    }
  }

  @objc
  public func checkWalletAvailability() -> Bool {
    return isPassKitAvailable();
  }
  
  @objc
  public func IOSPresentAddPaymentPassView(cardData: NSDictionary, completion: @escaping CompletionHandler) {
    guard isPassKitAvailable() else {
      completion(.error, [
        "errorMessage": "InApp enrollment not available for this device"
      ])
      return
    }
    
    let card: CardInfo
    do {
      card = try CardInfo(cardData: cardData)
    }
    catch {
      completion(.error, [
        "errorMessage": "Invalid card data. Please check your card information and try again..."
      ])
      return
    }
    
    guard let configuration = PKAddPaymentPassRequestConfiguration(encryptionScheme: .ECC_V2) else {
      completion(.error, [
        "errorMessage": "InApp enrollment configuraton fails"
      ])
      return
    }
    
    configuration.cardholderName = card.cardHolderName
    configuration.primaryAccountSuffix = card.lastDigits
    configuration.localizedDescription = String(card.cardDescription)
    configuration.paymentNetwork = card.network
    configuration.primaryAccountIdentifier = card.primaryAccountIdentifier

    guard let enrollViewController = PKAddPaymentPassViewController(requestConfiguration: configuration, delegate: self) else {
      completion(.error, [
        "errorMessage": "InApp enrollment controller configuration fails"
      ])
      return
    }
    
    presentAddPaymentPassCompletionHandler = completion
    DispatchQueue.main.async {
      if self.addPassViewController == nil {
        self.addPassViewController = enrollViewController
        RCTPresentedViewController()?.present(enrollViewController, animated: true, completion: nil)
      } else {
        self.logInfo(message: "EnrollViewController is already presented.")
      }
    }
  }
  
  @objc
  public func IOSHandleAddPaymentPassResponse(payload: NSDictionary, completion: @escaping CompletionHandler) {
    guard addPassHandler != nil else {
      hideModal()
      completion(.error, [
        "errorMessage": "addPassHandler unavailable"
      ])
      return
    }

    let walletData: WalletEncryptedPayload
    do {
      walletData = try WalletEncryptedPayload(data: payload)
    } catch {
      hideModal()
      completion(.error, [
        "errorMessage": "Invalid payload data"
      ])
      return
    }
    
    self.addPaymentPassCompletionHandler = completion
    
    let addPaymentPassRequest = PKAddPaymentPassRequest()
    addPaymentPassRequest.encryptedPassData = walletData.encryptedPassData
    addPaymentPassRequest.activationData = walletData.activationData
    addPaymentPassRequest.ephemeralPublicKey = walletData.ephemeralPublicKey
    self.addPassHandler?(addPaymentPassRequest)
    self.addPassHandler = nil
  }
  
  private func getPassActivationState(matching condition: (PKSecureElementPass) -> Bool) -> NSNumber {
    let paymentPasses = passLibrary.passes(of: .payment)
    if paymentPasses.isEmpty {
      self.logInfo(message: "No passes found in Wallet.")
      return -1
    }
    
    for pass in paymentPasses {
      guard let securePassElement = pass.secureElementPass else { continue }
      if condition(securePassElement) {
        return NSNumber(value: securePassElement.passActivationState.rawValue)
      }
    }
    return -1
  }
  
  @objc public func getCardStatusBySuffix(last4Digits: NSString) -> NSNumber {
    return getPassActivationState { pass in
      return pass.primaryAccountNumberSuffix.hasSuffix(last4Digits as String)
    }
  }

  @objc public func getCardStatusByIdentifier(identifier: NSString) -> NSNumber {
    return getPassActivationState { pass in
      return pass.primaryAccountIdentifier == identifier as String
    }
  }

  @objc
  public func canAddSecureElementPass(primaryAccountIdentifier: NSString) -> Bool {
    guard !primaryAccountIdentifier.isEqual(to: "") else {
      return false
    }

    if #available(iOS 13.4, *) {
      return passLibrary.canAddSecureElementPass(primaryAccountIdentifier: primaryAccountIdentifier as String)
    }

    return false
  }

  @objc
  public func listAppleWalletPasses() -> [NSDictionary] {
    let localPasses = passLibrary.passes(of: .secureElement).compactMap { pass -> NSDictionary? in
      guard let secureElementPass = pass.secureElementPass else {
        return nil
      }

      return makeAppleWalletPassDictionary(
        passTypeIdentifier: pass.passTypeIdentifier,
        serialNumber: pass.serialNumber,
        primaryAccountIdentifier: secureElementPass.primaryAccountIdentifier,
        lastDigits: secureElementPass.primaryAccountNumberSuffix,
        activationState: secureElementPass.passActivationState.rawValue,
        isRemote: pass.isRemotePass
      )
    }

    let remotePasses = passLibrary.remoteSecureElementPasses.map { pass in
      makeAppleWalletPassDictionary(
        passTypeIdentifier: pass.passTypeIdentifier,
        serialNumber: pass.serialNumber,
        primaryAccountIdentifier: pass.primaryAccountIdentifier,
        lastDigits: pass.primaryAccountNumberSuffix,
        activationState: pass.passActivationState.rawValue,
        isRemote: true
      )
    }

    return localPasses + remotePasses
  }

  @objc
  public func activateAppleWalletPass(passData: NSDictionary, completion: @escaping CompletionHandler) {
    guard passLibrary.isSecureElementPassActivationAvailable else {
      completion(.error, [
        "errorMessage": "Secure Element pass activation is not available for this device"
      ])
      return
    }

    guard
      let passTypeIdentifier = passData["passTypeIdentifier"] as? String,
      !passTypeIdentifier.isEmpty,
      let serialNumber = passData["serialNumber"] as? String,
      !serialNumber.isEmpty,
      let activationDataString = passData["activationData"] as? String,
      !activationDataString.isEmpty
    else {
      completion(.error, [
        "errorMessage": "Invalid pass activation data"
      ])
      return
    }

    guard let activationData = Data(base64Encoded: activationDataString) else {
      completion(.error, [
        "errorMessage": "activationData must be a valid base64 encoded string"
      ])
      return
    }

    guard let secureElementPass = findSecureElementPass(
      passTypeIdentifier: passTypeIdentifier,
      serialNumber: serialNumber
    ) else {
      completion(.error, [
        "errorMessage": "Secure Element pass not found"
      ])
      return
    }

    if secureElementPass.passActivationState == .activated {
      completion(.completed, ["success": true])
      return
    }

    guard secureElementPass.passActivationState == .requiresActivation else {
      completion(.error, [
        "errorMessage": "Secure Element pass is not eligible for activation. Current state: \(secureElementPass.passActivationState.rawValue)"
      ])
      return
    }

    passLibrary.activate(secureElementPass, activationData: activationData) { success, error in
      if let error {
        completion(.error, [
          "errorMessage": error.localizedDescription
        ])
        return
      }

      completion(.completed, ["success": success])
    }
  }
  
  private func isPassKitAvailable() -> Bool {
    return PKAddPaymentPassViewController.canAddPaymentPass()
  }
  
  private func findSecureElementPass(passTypeIdentifier: String, serialNumber: String) -> PKSecureElementPass? {
    if let pass = passLibrary.pass(withPassTypeIdentifier: passTypeIdentifier, serialNumber: serialNumber)?.secureElementPass {
      return pass
    }

    return passLibrary.remoteSecureElementPasses.first { pass in
      pass.passTypeIdentifier == passTypeIdentifier && pass.serialNumber == serialNumber
    }
  }

  private func makeAppleWalletPassDictionary(
    passTypeIdentifier: String,
    serialNumber: String,
    primaryAccountIdentifier: String?,
    lastDigits: String?,
    activationState: Int,
    isRemote: Bool
  ) -> NSDictionary {
    let result = NSMutableDictionary(dictionary: [
      "passTypeIdentifier": passTypeIdentifier,
      "serialNumber": serialNumber,
      "activationState": activationState,
      "isRemote": isRemote
    ])

    if let primaryAccountIdentifier, !primaryAccountIdentifier.isEmpty {
      result["primaryAccountIdentifier"] = primaryAccountIdentifier
    }

    if let lastDigits, !lastDigits.isEmpty {
      result["lastDigits"] = lastDigits
    }

    return result
  }

  private func hideModal() {
    DispatchQueue.main.async {
      if let enrollVC = self.addPassViewController, enrollVC.isBeingPresented || enrollVC.presentingViewController != nil {
        enrollVC.dismiss(animated: true, completion: {
          self.addPassViewController = nil
        })
      } else {
        self.logInfo(message: "EnrollViewController is not presented currently.")
      }
    }
  }
  
  private func logInfo(message: String) {
    print("[\(packageName)] \(message)")
  }
}

extension WalletManager: PKAddPaymentPassViewControllerDelegate {
  // Perform the bridge from Apple -> Issuer -> Apple
  public func addPaymentPassViewController(
    _ controller: PKAddPaymentPassViewController,
    generateRequestWithCertificateChain certificates: [Data],
    nonce: Data, nonceSignature: Data,
    completionHandler handler: @escaping (PKAddPaymentPassRequest) -> Void) {
      let stringNonce = nonce.base64EncodedString() as NSString
      let stringNonceSignature = nonceSignature.base64EncodedString() as NSString
      let stringCertificates = certificates.map {
        $0.base64EncodedString() as NSString
      }
      let reqestCardData = AddPassResponse(status: .completed, nonce: stringNonce, nonceSignature: stringNonceSignature, certificates: stringCertificates)
      self.addPassHandler = handler
      
      // Retry the JS issuer callback if the user tries again to add a payment pass
      if let addPaymentPassHandler = addPaymentPassCompletionHandler {
        addPaymentPassHandler(.retry, reqestCardData.toNSDictionary())
        addPaymentPassCompletionHandler = nil
        return
      }
      
      // Finish IOSPresentAddPaymentPassView function
      if let presentPassHandler = presentAddPaymentPassCompletionHandler {
        presentPassHandler(.completed, reqestCardData.toNSDictionary())
        presentAddPaymentPassCompletionHandler = nil
      }
    }
    
  // This method will be called when enroll process ends (with success/error)
  public func addPaymentPassViewController(
    _ controller: PKAddPaymentPassViewController,
    didFinishAdding pass: PKPaymentPass?,
    error: Error?) {
      if addPassViewController == nil {
        return
      }
      
      let errorMessage = error?.localizedDescription ?? ""

      if error != nil {
        self.logInfo(message: "Error: \(errorMessage)")
        delegate?.sendEvent(name: Event.onCardActivated.rawValue, result:  [
          "status": "canceled"
        ]);
      }
      
      // Cancel the IOSPresentAddPaymentPassView function when the user cancelled the modal
      if let handler = presentAddPaymentPassCompletionHandler {
        let response = AddPassResponse(status: .canceled, nonce: nil, nonceSignature: nil, certificates: nil)
        handler(.canceled, response.toNSDictionary())
      }
      
      // If the pass is returned complete the IOSHandleAddPaymentPassResponse function
      if let addPaymentPassHandler = addPaymentPassCompletionHandler {
        if pass != nil {
          addPaymentPassHandler(.completed, nil)
        } else {
          addPaymentPassHandler(.error, [
            "errorMessage": "Could not add card. \(errorMessage))."
          ])
        }
      }
      
      hideModal()
      addPaymentPassCompletionHandler = nil
      presentAddPaymentPassCompletionHandler = nil
    }
}

extension WalletManager {
  enum Event: String, CaseIterable {
    case onCardActivated
  }

  @objc
  public static var supportedEvents: [String] {
    return Event.allCases.map(\.rawValue);
  }
}
