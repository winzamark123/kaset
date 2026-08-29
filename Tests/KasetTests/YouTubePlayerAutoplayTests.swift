import Foundation
import Testing
@testable import Kaset

@Suite("YouTube related video autoplay", .serialized, .tags(.service), .timeLimit(.minutes(1)))
@MainActor
struct YouTubePlayerAutoplayTests {
    private let controller: MockYouTubeWatchPlaybackController
    private let sut: YouTubePlayerService

    init() {
        self.controller = MockYouTubeWatchPlaybackController()
        self.sut = YouTubePlayerService(
            playbackController: self.controller,
            shouldAutoplayRelatedVideos: { true }
        )
    }

    @Test("Video end does not autoplay when the setting is disabled")
    func videoEndDoesNotAutoplayWhenDisabled() async {
        let controller = MockYouTubeWatchPlaybackController()
        let sut = YouTubePlayerService(
            playbackController: controller,
            shouldAutoplayRelatedVideos: { false }
        )
        sut.play(video: MockYouTubeClient.makeVideo(videoId: "current"))
        sut.setUpNext([MockYouTubeClient.makeVideo(videoId: "next")])
        sut.handleVideoEnded(videoId: "current")
        // give a wrongly scheduled transition the chance to run before asserting
        for _ in 0 ..< 10 {
            await Task.yield()
        }

        #expect(sut.currentVideo?.videoId == "current")
        #expect(controller.loadedVideoIds == ["current"])
    }

    @Test("Manual terminal seek triggers autoplay")
    func manualTerminalSeekTriggersAutoplay() async {
        self.finishCurrentVideo(
            upNext: [MockYouTubeClient.makeVideo(videoId: "next")],
            isNativeTerminal: true
        )
        await self.waitUntil(self.sut.currentVideo?.videoId == "next", "autoplay to next")

        #expect(self.controller.loadedVideoIds == ["current", "next"])
    }

    @Test("Video end autoplays a cached related video")
    func videoEndAutoplaysCachedRelatedVideo() async {
        self.finishCurrentVideo(upNext: [MockYouTubeClient.makeVideo(videoId: "next")])
        await self.waitUntil(self.sut.currentVideo?.videoId == "next", "autoplay to next")

        #expect(self.controller.loadedVideoIds == ["current", "next"])
    }

    @Test("Video end fetches a related video when up next is empty")
    func videoEndFetchesRelatedVideo() async {
        let client = self.stubRelatedVideos(["fetched"])
        self.finishCurrentVideo()
        await self.waitUntil(self.sut.currentVideo?.videoId == "fetched", "autoplay to fetched")

        #expect(client.requestedWatchNextVideoIds == ["current"])
    }

    @Test("Video end stays stopped when no related video is available")
    func videoEndWithoutRelatedVideoStaysStopped() async {
        let client = self.stubRelatedVideos()
        self.finishCurrentVideo()
        await self.waitUntil(client.getWatchNextCompletionCount == 1, "watch-next request")

        #expect(client.requestedWatchNextVideoIds == ["current"])
        #expect(self.sut.currentVideo?.videoId == "current")
        #expect(self.controller.loadedVideoIds == ["current"])
        #expect(!self.sut.isPlaying)
    }

    @Test("A newer user selection invalidates a pending autoplay lookup")
    func newerSelectionInvalidatesPendingAutoplay() async {
        let client = self.stubRelatedVideos(["stale-next"])
        let requestStarted = AsyncGate()
        let releaseRequest = AsyncGate()
        client.beforeWatchNextReturn = { _ in
            await requestStarted.open()
            await releaseRequest.wait()
        }
        self.finishCurrentVideo(videoId: "ended")
        await requestStarted.wait()

        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: "selected"))
        await releaseRequest.open()
        await self.waitUntil(client.getWatchNextCompletionCount == 1, "watch-next request")

        #expect(self.sut.currentVideo?.videoId == "selected")
        #expect(self.controller.loadedVideoIds == ["ended", "selected"])
    }

    @Test("Duplicate ended callbacks schedule one autoplay transition")
    func duplicateEndedCallbacksScheduleOneAutoplay() async {
        self.finishCurrentVideo(upNext: [MockYouTubeClient.makeVideo(videoId: "next")])
        self.sut.handleVideoEnded(videoId: "current")
        await self.waitUntil(self.sut.currentVideo?.videoId == "next", "autoplay to next")

        #expect(self.controller.loadedVideoIds == ["current", "next"])
    }

    /// Installs a client whose watch-next response lists `videoIds` as related.
    private func stubRelatedVideos(_ videoIds: [String] = []) -> MockYouTubeClient {
        let client = MockYouTubeClient()
        client.watchNextData = WatchNextData(
            videoTitle: nil,
            viewCountText: nil,
            publishedText: nil,
            channel: nil,
            related: videoIds.map { MockYouTubeClient.makeVideo(videoId: $0) }
        )
        self.sut.youtubeClient = client
        return client
    }

    private func finishCurrentVideo(
        videoId: String = "current",
        upNext: [YouTubeVideo] = [],
        isNativeTerminal: Bool = false
    ) {
        self.sut.play(video: MockYouTubeClient.makeVideo(videoId: videoId))
        self.sut.setUpNext(upNext)
        self.sut.handleVideoEnded(videoId: videoId, isNativeTerminal: isNativeTerminal)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool, _ description: String) async {
        for _ in 0 ..< 1000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        Issue.record("Timed out waiting for \(description)")
    }
}
