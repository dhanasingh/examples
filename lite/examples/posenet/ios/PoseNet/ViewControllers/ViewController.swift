// Copyright 2019 The TensorFlow Authors. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AVFoundation
import UIKit
import AVKit
import os
import Photos
import MobileCoreServices

private let ONE_FRAME_DURATION = 0.03
private var AVPlayerItemStatusContext: Int = Int()


class ViewController: UIViewController {
  // MARK: Storyboards Connections
  @IBOutlet weak var previewView: PreviewView!

  @IBOutlet weak var overlayView: OverlayView!

  @IBOutlet weak var resumeButton: UIButton!
  @IBOutlet weak var cameraUnavailableLabel: UILabel!

 // @IBOutlet weak var tableView: UITableView!

  @IBOutlet weak var threadCountLabel: UILabel!
  @IBOutlet weak var threadCountStepper: UIStepper!

  @IBOutlet weak var delegatesControl: UISegmentedControl!

  // MARK: ModelDataHandler traits
  var threadCount: Int = Constants.defaultThreadCount
  //var delegate: Delegates = Constants.defaultDelegate

  // MARK: Result Variables
  // Inferenced data to render.
  private var inferencedData: InferencedData?

  // Minimum score to render the result.
  private let minimumScore: Float = 0.5

  // Handles all data preprocessing and makes calls to run inference.
  private var modelDataHandler: ModelDataHandler?
    
    
    //@objc private dynamic var player: AVPlayer!
    private var videoOutput: AVPlayerItemVideoOutput!
    private var displayLink: CADisplayLink!
    private var _myVideoOutputQueue: DispatchQueue!
    private var _notificationToken: AnyObject?
    private var _timeObserver: AnyObject?
    
    var imagePicker = UIImagePickerController()
    var playCtrl = AVPlayerViewController()

    var videoURL : NSURL?



  // MARK: View Handling Methods
  override func viewDidLoad() {
    super.viewDidLoad()

    do {
      modelDataHandler = try ModelDataHandler()
    } catch let error {
      fatalError(error.localizedDescription)
    }

    // MARK: UI Initialization
    // Setup thread count stepper with white color.
    // https://forums.developer.apple.com/thread/121495

        
        playCtrl.player = AVPlayer()
        
        // Setup CADisplayLink which will callback displayPixelBuffer: at every vsync.
        self.displayLink = CADisplayLink(target: self, selector: #selector(ViewController.displayLinkCallback(_:)))
        //self.displayLink.add(to: RunLoop.current, forMode: .default)
        self.displayLink.add(to: .current, forMode: .default)
        self.displayLink.isPaused = true
        
        // Setup AVPlayerItemVideoOutput with the required pixelbuffer attributes.
        let pixBuffAttributes: [String : AnyObject] = [kCVPixelBufferPixelFormatTypeKey as String :
            Int(kCVPixelFormatType_32BGRA) as AnyObject]
            //Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) as AnyObject]
        self.videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixBuffAttributes)
        _myVideoOutputQueue = DispatchQueue(label: "myVideoOutputQueue", attributes: [])
        self.videoOutput.setDelegate(self, queue: _myVideoOutputQueue)
        playCtrl.contentOverlayView?.addSubview(overlayView)
        //self.requestPhotoPermission()
    }
    

  override func viewWillDisappear(_ animated: Bool) {
    //cameraCapture.stopSession()
  }

  override func viewDidLayoutSubviews() {
        self.overlayView.frame = playCtrl.view.frame

  }
    
    @IBAction func selectVideo(_ sender: Any) {
        imagePicker.sourceType = .savedPhotosAlbum
        imagePicker.delegate = self
        imagePicker.mediaTypes = [kUTTypeMovie as String]
        present(imagePicker, animated: true, completion: nil)
    }
    
    private func setupPlaybackForURL() {
        /*
        Sets up player item and adds video output to it.
        The tracks property of an asset is loaded via asynchronous key value loading, to access the preferred transform of a video track used to orientate the video while rendering.
        After adding the video output, we request a notification of media change in order to restart the CADisplayLink.
        */
        
        // Remove video output from old item, if any.
        playCtrl.player?.currentItem?.remove(self.videoOutput)
        
        let item = AVPlayerItem(url: self.videoURL as! URL)
        let asset = item.asset
        
        asset.loadValuesAsynchronously(forKeys: ["tracks"]) {
            
            var error: NSError? = nil
            let status = asset.statusOfValue(forKey: "tracks", error: &error)
            if status == .loaded {
                let tracks = asset.tracks(withMediaType: .video)
                if !tracks.isEmpty {
                    // Choose the first video track.
                    let videoTrack = tracks[0]
                    videoTrack.loadValuesAsynchronously(forKeys: ["preferredTransform"]) {
                        
                        if videoTrack.statusOfValue(forKey: "preferredTransform", error: nil) == .loaded {
                            let preferredTransform = videoTrack.preferredTransform
                            
                            DispatchQueue.main.async {
                                item.add(self.videoOutput)
                                self.playCtrl.player?.replaceCurrentItem(with: item)
                                self.videoOutput.requestNotificationOfMediaDataChange(withAdvanceInterval: ONE_FRAME_DURATION)
                                
                                self.playCtrl.player?.play()
                            }
                            
                        }
                        
                    }
                }
            } else {
                print(status, error ?? "url Playback setup error")
            }
            
        }
        
    }
    
    private func stopLoadingAnimationAndHandleError(_ error: NSError?) {
        guard let error = error else {return}
        let cancelButtonTitle =  NSLocalizedString("OK", comment: "Cancel button title for animation load error")
        if #available(iOS 8.0, *) {
            let alertController = UIAlertController(title: error.localizedDescription, message: error.localizedFailureReason, preferredStyle: .alert)
            let action = UIAlertAction(title: cancelButtonTitle, style: .cancel, handler: nil)
            alertController.addAction(action)
            self.present(alertController, animated: true, completion: nil)
        } else {
            let alertView = UIAlertView(title: error.localizedDescription, message: error.localizedFailureReason, delegate: nil, cancelButtonTitle: cancelButtonTitle)
            alertView.show()
        }
    }

     //MARK: - CADisplayLink Callback
     
     @objc func displayLinkCallback(_ sender: CADisplayLink) {
         /*
         The callback gets called once every Vsync.
         Using the display link's timestamp and duration we can compute the next time the screen will be refreshed, and copy the pixel buffer for that time
         This pixel buffer can then be processed and later rendered on screen.
         */
         var outputItemTime = CMTime.invalid
         
         // Calculate the nextVsync time which is when the screen will be refreshed next.
         let nextVSync = (sender.timestamp + sender.duration)
         
         outputItemTime = self.videoOutput.itemTime(forHostTime: nextVSync)
         
         if self.videoOutput.hasNewPixelBuffer(forItemTime: outputItemTime) {
            let pixelBuffer = self.videoOutput.copyPixelBuffer(forItemTime: outputItemTime, itemTimeForDisplay: nil)!
             
            runModel(on: pixelBuffer)
             
         }
     }
    
      @objc func runModel(on pixelBuffer: CVPixelBuffer) {
        let previewViewFrame = playCtrl.view.frame

        // get the transformation between pixelbuffer and preview view
        
        overlayView.overlayTransform  = pixelBuffer.size.transformKeepAspect(toFitIn: previewViewFrame.size)
        
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        
        let modelInputRange = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height));
        
        // Run PoseNet model.
        guard
          let (result, times) = self.modelDataHandler?.runPoseNet(
            on: pixelBuffer,
            from: modelInputRange,
            to: modelInputRange.size)
        else {
          os_log("Cannot get inference result.", type: .error)
          return
        }

        // Udpate `inferencedData` to render data in `tableView`.
        inferencedData = InferencedData(score: result.score, times: times)
        // Draw result.
        DispatchQueue.main.async {
    //      self.tableView.reloadData()
          // If score is too low, clear result remaining in the overlayView.
          if result.score < self.minimumScore {
            self.clearResult()
            return
          }
          self.drawResult(of: result)
        }
      }

      func drawResult(of result: Result) {
        self.overlayView.dots = result.dots
        self.overlayView.lines = result.lines
        self.overlayView.setNeedsDisplay()
      }

      func clearResult() {
        self.overlayView.clear()
        self.overlayView.setNeedsDisplay()
      }

    //### We need an explicit authorization to access properties of assets in Photos.
     private func requestPhotoPermission() {
         let status = PHPhotoLibrary.authorizationStatus()
         switch status {
         case .authorized:
             return
         case .denied:
             return
         case .notDetermined, .restricted:
             PHPhotoLibrary.requestAuthorization {newStatus in
                 //Do nothing as for now...
             }
         @unknown default:
             break
         }
     }
    
  // MARK: Button Actions
  @IBAction func didChangeThreadCount(_ sender: UIStepper) {
    let changedCount = Int(sender.value)
    if threadCountLabel.text == changedCount.description {
      return
    }

    do {
      modelDataHandler = try ModelDataHandler(threadCount: changedCount)
    } catch let error {
      fatalError(error.localizedDescription)
    }
    threadCount = changedCount
    threadCountLabel.text = changedCount.description
    os_log("Thread count is changed to: %d", threadCount)
  }

  @IBAction func didChangeDelegate(_ sender: UISegmentedControl) {
    guard let changedDelegate = Delegates(rawValue: delegatesControl.selectedSegmentIndex) else {
      fatalError("Unexpected value from delegates segemented controller.")
    }
    do {
      modelDataHandler = try ModelDataHandler(threadCount: threadCount, delegate: changedDelegate)
    } catch let error {
      fatalError(error.localizedDescription)
    }
    //delegate = changedDelegate
    os_log("Delegate is changed to: ")
  }

  func presentUnableToResumeSessionAlert() {
    let alert = UIAlertController(
      title: "Unable to Resume Session",
      message: "There was an error while attempting to resume session.",
      preferredStyle: .alert
    )
    alert.addAction(UIAlertAction(title: "OK", style: .default, handler: nil))

    self.present(alert, animated: true)
  }
}


//MARK: - AVPlayerItemOutputPullDelegate

extension ViewController: AVPlayerItemOutputPullDelegate {
    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        // Restart display link.
        self.displayLink.isPaused = false
    }

}

extension ViewController: UIImagePickerControllerDelegate {
    public func imagePickerController(_ picker: UIImagePickerController,
    didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        
        self.videoURL = info[UIImagePickerController.InfoKey.mediaURL] as? NSURL

        self.dismiss(animated: true, completion: nil)
        present(playCtrl, animated: true, completion: nil)
        setupPlaybackForURL()

    }
    
    public func imagePickerControllerDidCancel(_ picker: UIImagePickerController){
        self.dismiss(animated: true, completion: nil)
    }
}

extension ViewController: UINavigationControllerDelegate {
    //empty implementation
}

// MARK: - Private enums
/// UI coinstraint values
fileprivate enum Traits {
  static let normalCellHeight: CGFloat = 35.0
  static let separatorCellHeight: CGFloat = 25.0
  static let bottomSpacing: CGFloat = 30.0
    
}

fileprivate struct InferencedData {
  var score: Float
  var times: Times
}

/// Type of sections in Info Cell
fileprivate enum InferenceSections: Int, CaseIterable {
  case Score
  case Time

  var description: String {
    switch self {
    case .Score:
      return "Score"
    case .Time:
      return "Processing Time"
    }
  }

  var subcaseCount: Int {
    switch self {
    case .Score:
      return 1
    case .Time:
      return ProcessingTimes.allCases.count
    }
  }
}

/// Type of processing times in Time section in Info Cell
fileprivate enum ProcessingTimes: Int, CaseIterable {
  case InferenceTime

  var description: String {
    switch self {
    case .InferenceTime:
      return "Inference Time"
    }
  }
}
