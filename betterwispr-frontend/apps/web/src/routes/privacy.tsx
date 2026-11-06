import { createFileRoute } from "@tanstack/react-router";
import { pageHead } from "@/lib/seo";

export const Route = createFileRoute("/privacy")({
  head: () =>
    pageHead(
      "Privacy | BetterWispr",
      "How BetterWispr handles speech, local transcripts, model downloads and website visits.",
      "/privacy",
    ),
  component: () => (
    <article className="legal-page">
      <p className="eyebrow">Your data</p>
      <h1>Privacy</h1>
      <p>
        BetterWispr’s built in speech models process dictation on your Mac.
        The app has no account and never falls back to cloud transcription.
        Audio or text leaves your Mac only through a provider you select.
      </p>
      <h2>Speech and model downloads</h2>
      <p>
        Microphone audio is processed by your selected local speech provider.
        Downloadable models and tokenizers require an explicit installation
        action. Apple speech requires a supported on device language and OS
        assets. Downloads and app update checks use an internet connection.
      </p>
      <p>
        You can select a speech API connection, such as Sarvam AI, Smallest AI
        or an OpenAI compatible endpoint, or a notes model from Claude Code,
        Codex or an API connection. That provider then receives your recordings
        or text for transcription, meeting notes or Medium cleanup, under its
        own privacy practices. If you turn on Allow any Claude Code sign-in, off
        by default, meeting text can go to the destination Claude Code reports,
        such as an API account, a company cloud account or a gateway, after you
        confirm that destination in Models. This switch applies only to meeting
        notes: Ask, Medium cleanup and correction review still need a Claude
        subscription. BetterWispr shows what Claude Code reports and what its
        settings files on your Mac say, and can’t verify the destination beyond
        that. API keys are stored in your login Keychain.
        Apple Intelligence and Ollama notes models run on your Mac.
      </p>
      <h2>History and recordings</h2>
      <p>
        Settings, vocabulary and optional dictation history are stored in your
        Mac’s Application Support folder. Dictation history includes both raw
        and corrected text and is enabled by default. You can turn history off
        for future dictations. This local data is not encrypted by the app.
      </p>
      <p>
        Temporary dictation recordings are removed after normal completion or
        cancellation. Force quitting or a system crash can interrupt cleanup.
        Meeting recordings are a separate feature with their own local saved
        files.
      </p>
      <h2>Permissions and other apps</h2>
      <p>
        Microphone access is needed to record. Accessibility access is used to
        insert text in another app, and Apple speech requires Speech Recognition
        permission. Automatic insertion can use the clipboard. The destination
        app handles the inserted text under its own privacy practices.
      </p>
      <h2>This website</h2>
      <p>
        The website does not request microphone access or upload speech. Hosting
        providers process network requests to serve the site. Following a
        download, GitHub or other external link takes you to that service and
        its privacy practices.
      </p>
      <h2>Contact</h2>
      <p>
        Questions about BetterWispr can be sent to{" "}
        <a href="https://x.com/code_kartik">Kartik Labhshetwar</a>.
      </p>
    </article>
  ),
});
