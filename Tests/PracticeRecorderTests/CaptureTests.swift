import XCTest
import AVFoundation
import PracticeRecorderCore
@testable import PracticeRecorderMedia

final class CaptureTests: XCTestCase {
    func testMissingCameraDoesNotFallback() {
        let pipeline = CapturePipeline()
        let done = expectation(description:"missing selection fails")
        pipeline.configure(CaptureSelection(cameraID:"nonexistent-camera",audioDeviceID:"nonexistent-audio",leftChannel:10,rightChannel:11,video:QualityProfile.p720_30.video)) { result in
            switch result { case .success: XCTFail("Missing device must not fall back"); case .failure: break }
            done.fulfill()
        }
        wait(for:[done],timeout:5)
    }
    func testHardwareReconfigureRejectsOldOutputCallbacks() throws {
        guard ProcessInfo.processInfo.environment["PRACTICE_RECORDER_HARDWARE_TEST"] == "1" else { throw XCTSkip("Opt-in live reconfiguration test") }
        guard AVCaptureDevice.authorizationStatus(for:.video) == .authorized, AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { throw XCTSkip("Camera/microphone permission unavailable to test host") }
        let cameras = CapturePipeline.cameras()
        let first = try XCTUnwrap(cameras.first(where: {$0.name.contains("HP HD Camera")}))
        let second = try XCTUnwrap(cameras.first(where: {$0.name.contains("MacBook")}))
        let audio = try XCTUnwrap(CapturePipeline.audioDevices().first(where: {$0.name.contains("Fireface UCX II")}))
        let pipeline = CapturePipeline()
        pipeline.onError = { XCTFail("Unexpected reconfiguration error: \($0)") }
        for (camera,quality) in [(first, QualityProfile.p720_30), (second, QualityProfile.p1080_30), (first, QualityProfile.p720_30)] {
            let ready = expectation(description:"native input after reconfigure \(camera.name)")
            let stable = expectation(description:"streams remain stable after reconfigure")
            pipeline.configure(CaptureSelection(cameraID:camera.id,audioDeviceID:audio.id,leftChannel:10,rightChannel:11,video:quality.video)) { result in
                switch result {
                case .success(let info):
                    XCTAssertEqual(info.audioChannels,20); XCTAssertEqual(info.sampleRate,48000)
                    print("REAL RECONFIGURE: \(camera.name) \(info.audioDescription); \(info.video.title)")
                case .failure(let error): XCTFail(error.localizedDescription)
                }
                ready.fulfill()
                DispatchQueue.global().asyncAfter(deadline:.now()+1) { stable.fulfill() }
            }
            wait(for:[ready,stable],timeout:8)
        }
        let stopped = expectation(description:"reconfigured session stopped")
        pipeline.stop { stopped.fulfill() }
        wait(for:[stopped],timeout:5)
    }
    func testHardwareCaptureSelectedRME1112() throws {
        guard ProcessInfo.processInfo.environment["PRACTICE_RECORDER_HARDWARE_TEST"] == "1" else { throw XCTSkip("Opt-in live hardware test: PRACTICE_RECORDER_HARDWARE_TEST=1 swift test --filter CaptureTests/testHardwareCaptureSelectedRME1112") }
        guard AVCaptureDevice.authorizationStatus(for:.video) == .authorized, AVCaptureDevice.authorizationStatus(for:.audio) == .authorized else { throw XCTSkip("Camera/microphone permission unavailable to test host") }
        let camera = try XCTUnwrap(CapturePipeline.cameras().first(where: {$0.name.contains("HP HD Camera")}))
        let audio = try XCTUnwrap(CapturePipeline.audioDevices().first(where: {$0.name.contains("Fireface UCX II")}))
        let pipeline = CapturePipeline()
        let ready = expectation(description:"actual native input format")
        let audioReceived = expectation(description:"selected stereo PCM received")
        let videoReceived = expectation(description:"actual camera buffer received")
        var audioOnce = false, videoOnce = false
        pipeline.onError = { XCTFail($0) }
        pipeline.onAudio = { buffer in
            if !audioOnce {
                audioOnce = true
                let format = CMSampleBufferGetFormatDescription(buffer)!
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)!.pointee
                XCTAssertEqual(asbd.mChannelsPerFrame,2)
                XCTAssertEqual(asbd.mSampleRate,48000)
                XCTAssertGreaterThan(CMSampleBufferGetNumSamples(buffer),0)
                print("REAL SELECTED AUDIO Ch11/12: \(asbd), PTS \(CMSampleBufferGetPresentationTimeStamp(buffer))")
                audioReceived.fulfill()
            }
        }
        pipeline.onVideo = { buffer in
            if !videoOnce { videoOnce = true; print("REAL VIDEO PTS \(CMSampleBufferGetPresentationTimeStamp(buffer))"); videoReceived.fulfill() }
        }
        pipeline.configure(CaptureSelection(cameraID:camera.id,audioDeviceID:audio.id,leftChannel:10,rightChannel:11,video:QualityProfile.p720_30.video)) { result in
            switch result {
            case .success(let info):
                XCTAssertEqual(info.audioChannels,20); XCTAssertEqual(info.sampleRate,48000)
                print("REAL CAPTURE: \(info.audioDescription); \(info.video.title)")
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            ready.fulfill()
        }
        wait(for:[ready,audioReceived,videoReceived],timeout:8)
        let stopped = expectation(description:"session stopped")
        pipeline.stop { stopped.fulfill() }
        wait(for:[stopped],timeout:5)
    }
}
