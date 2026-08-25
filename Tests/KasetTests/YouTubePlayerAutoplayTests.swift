import Foundation
import Testing
@testable import Kaset

// MARK: - YouTubeAutoplayTestContext

@MainActor
private final class YouTubeAutoplayTestContext {
    let controller = MockYouTubeWatchPlaybackController()
    var isAutoplayEnabled: Bool
    private(set) lazy var service = YouTubePlayerService(
        playbackController: self.controller,
        shouldAutoplayRelatedVideos: { [weak self] in self?.isAutoplayEnabled ?? false }
    )

    init(isAutoplayEnabled: Bool) {
        self.isAutoplayEnabled = isAutoplayEnabled
    }

    /// Installs a client whose watch-next response lists `videoIds` as related.
    @discardableResult
    func stubRelatedVideos(_ videoIds: [String] = []) -> MockYouTubeClient {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: nil,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: videoIds.map { MockYouTubeClient.makeVideo(videoId: $0) }
        )
        self.service.youtubeClient = client
        return client
    }

    func finishCurrentVideo(
        videoId: String = "current",
        upNext: [YouTubeVideo] = [],
        popOut: Bool = false,
        isNativeTerminal: Bool = false
    ) {
        self.service.play(video: MockYouTubeClient.makeVideo(videoId: videoId))
        if popOut {
            self.service.popOutToWindow()
        }
        self.service.setUpNext(upNext)
        self.service.updatePlaybackState(.init(
            isPlaying: true,
            progress: 59,
            duration: 60,
            videoId: videoId,
            title: nil,
            isAd: false
        ))
        self.service.handleVideoEnded(
            videoId: videoId,
            isNativeTerminal: isNativeTerminal
        )
    }
}

// MARK: - YouTubePlayerAutoplayTests

@Suite("YouTube related video autoplay", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePlayerAutoplayTests {
    @Test("Video end does not autoplay when the setting is disabled")
    func videoEndDoesNotAutoplayWhenDisabled() {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: false)
        context.finishCurrentVideo(
            upNext: [MockYouTubeClient.makeVideo(videoId: "next")]
        )

        #expect(context.service.currentVideo?.videoId == "current")
        #expect(context.controller.loadedVideoIds == ["current"])
        #expect(!context.service.isPlaying)
    }

    @Test("Manual terminal seek triggers autoplay")
    func manualTerminalSeekTriggersAutoplay() async {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: true)
        context.finishCurrentVideo(
            upNext: [MockYouTubeClient.makeVideo(videoId: "next")],
            isNativeTerminal: true
        )
        await self.waitUntil(context.service.currentVideo?.videoId == "next")

        #expect(context.service.currentVideo?.videoId == "next")
        #expect(context.controller.loadedVideoIds == ["current", "next"])
    }

    @Test("Video end autoplays a cached related video and preserves the floating surface")
    func videoEndAutoplaysCachedRelatedVideo() async {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: true)
        context.finishCurrentVideo(
            upNext: [MockYouTubeClient.makeVideo(videoId: "next")],
            popOut: true
        )
        await self.waitUntil(context.service.currentVideo?.videoId == "next")

        #expect(context.service.currentVideo?.videoId == "next")
        #expect(context.service.surfaceLocation == .floating)
        #expect(context.controller.loadedVideoIds == ["current", "next"])
        #expect(context.service.skipNavigationRequest == nil)
    }

    @Test("Video end fetches a related video when up next is empty")
    func videoEndFetchesRelatedVideo() async {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: true)
        let client = context.stubRelatedVideos(["fetched"])
        context.finishCurrentVideo()
        await self.waitUntil(context.service.currentVideo?.videoId == "fetched")

        #expect(client.requestedWatchNextVideoIds == ["current"])
        #expect(context.service.currentVideo?.videoId == "fetched")
        #expect(context.service.skipNavigationRequest?.videoId == "fetched")
    }

    @Test("Video end stays stopped when no related video is available")
    func videoEndWithoutRelatedVideoStaysStopped() async {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: true)
        let client = context.stubRelatedVideos()
        context.finishCurrentVideo()
        await self.waitUntil(client.getWatchNextCompletionCount == 1)

        #expect(client.requestedWatchNextVideoIds == ["current"])
        #expect(context.service.currentVideo?.videoId == "current")
        #expect(context.controller.loadedVideoIds == ["current"])
        #expect(!context.service.isPlaying)
    }

    @Test("A newer user selection invalidates a pending autoplay lookup")
    func newerSelectionInvalidatesPendingAutoplay() async {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: true)
        let client = context.stubRelatedVideos(["stale-next"])
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        client.beforeWatchNextReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        context.finishCurrentVideo(videoId: "ended")
        await requestStarted.wait()

        context.service.play(video: MockYouTubeClient.makeVideo(videoId: "selected"))
        await releaseRequest.open()
        await self.waitUntil(client.getWatchNextCompletionCount == 1)

        #expect(context.service.currentVideo?.videoId == "selected")
        #expect(context.controller.loadedVideoIds == ["ended", "selected"])
    }

    @Test("Disabling autoplay invalidates a pending related-video lookup")
    func disablingAutoplayInvalidatesPendingLookup() async {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: true)
        let client = context.stubRelatedVideos(["next"])
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        client.beforeWatchNextReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        context.finishCurrentVideo()
        await requestStarted.wait()

        context.isAutoplayEnabled = false
        await releaseRequest.open()
        await self.waitUntil(client.getWatchNextCompletionCount == 1)

        #expect(context.service.currentVideo?.videoId == "current")
        #expect(context.controller.loadedVideoIds == ["current"])
        #expect(!context.service.isPlaying)
    }

    @Test("Duplicate ended callbacks schedule one autoplay transition")
    func duplicateEndedCallbacksScheduleOneAutoplay() async {
        let context = YouTubeAutoplayTestContext(isAutoplayEnabled: true)
        context.finishCurrentVideo(
            upNext: [MockYouTubeClient.makeVideo(videoId: "next")]
        )
        context.service.handleVideoEnded(videoId: "current")
        await self.waitUntil(context.service.currentVideo?.videoId == "next")

        #expect(context.service.currentVideo?.videoId == "next")
        #expect(context.controller.loadedVideoIds == ["current", "next"])
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async {
        for _ in 0 ..< 100 {
            if condition() {
                return
            }
            await Task.yield()
        }
    }
}
