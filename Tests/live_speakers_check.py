"""Scores provisional live speaker labels, or with --me the choice of Me on the microphone, on a synthetic conversation spoken by macOS `say` voices; needs Speaker detection installed."""
import argparse
import itertools
import json
import statistics
import subprocess
import tempfile
import wave
from pathlib import Path

LINES = [
    "Good morning everyone, thanks for joining. I want to start with the launch plan and then move on to the budget for next quarter.",
    "Sounds good. Before we start, I have a quick update on the design review. The team approved the new layout yesterday afternoon.",
    "That is great news. Did they mention anything about the onboarding flow, or is that still waiting on research?",
    "Still waiting. Research expects to finish the interviews by Thursday, and we should have a summary early next week.",
    "Okay. Then let us talk about the launch. We have three weeks left, and the largest risk is still the payment integration.",
    "I agree. The provider changed their sandbox twice this month, so our tests keep failing for reasons that have nothing to do with us.",
    "Can we pin the version?",
    "We can, but only until the end of the month. After that they remove the old endpoints entirely.",
    "Then I suggest we finish the migration first and move the marketing date by one week if we have to.",
    "I would rather not move the date. Let me check with the provider whether they can extend the old version for us.",
    "Fine. Please send a note after the call so that everyone knows who owns that follow up.",
    "Will do. On the budget, we are about ten percent under, mostly because the contractor started later than planned.",
    "Good. We could spend part of that on more testing devices, since the lab is always fully booked.",
    "Yes, please.",
    "I will write up the request today and share it in the channel so that finance can approve it before Friday.",
    "Thank you both. I think that covers everything, unless there is something else you would like to raise now.",
    "Nothing from me. Have a good week, and I will talk to you both on Monday.",
    "Same here. Thanks everyone, goodbye.",
]
SAMPLE = "This is a sample of my voice. I am reading a few plain sentences aloud so that my own lines can be told apart from the people who sit next to me in a meeting. " * 4
SAMPLE_SECONDS = 30
RATE = 16_000
GAP = 0.8


def conversation(voices, folder, repeats=1):
    turns = []
    frames = bytearray()
    for index, line in enumerate(LINES * repeats):
        clip = folder / f"{index}.wav"
        subprocess.run(["say", "-v", voices[index % len(voices)], "-o", str(clip), "--data-format=LEI16@16000", line], check=True)
        with wave.open(str(clip)) as audio:
            data = audio.readframes(audio.getnframes())
        start = len(frames) / 2 / RATE
        frames += data
        turns.append((start, len(frames) / 2 / RATE, index % len(voices)))
        frames += bytes(int(GAP * RATE) * 2)
    path = folder / "conversation.wav"
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(RATE)
        audio.writeframes(bytes(frames))
    return path, turns


def truth(chunk, turns):
    spoken = {}
    for start, end, voice in turns:
        overlap = min(end, chunk["start"] + chunk["duration"]) - max(start, chunk["start"])
        if overlap > 0:
            spoken[voice] = spoken.get(voice, 0) + overlap
    best = max(spoken, key=spoken.get)
    return best, spoken[best] / sum(spoken.values())


def accuracy(chunks, key, voices):
    labels = sorted({chunk[key] for chunk in chunks})
    total = sum(chunk["duration"] for chunk in chunks)
    slots = labels + [None] * max(0, voices - len(labels))
    best = 0
    for order in itertools.permutations(slots, voices):
        right = sum(chunk["duration"] for chunk in chunks if order[chunk["voice"]] == chunk[key])
        best = max(best, right)
    return best / total, len(labels)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", default=".build/debug/BetterWisprCLI")
    parser.add_argument("--voices", default="Daniel,Karen,Samantha")
    parser.add_argument("--repeats", type=int, default=1)
    parser.add_argument("--window", default="300")
    parser.add_argument("--me", help="one of the voices; the conversation is then microphone audio and a separate sample of this voice is the Me profile")
    arguments = parser.parse_args()
    voices = arguments.voices.split(",")
    with tempfile.TemporaryDirectory() as folder:
        path, turns = conversation(voices, Path(folder), arguments.repeats)
        command = [arguments.cli, "--live-speakers", str(path), "--window", arguments.window]
        if arguments.me:
            sample = Path(folder) / "me.wav"
            spoken = Path(folder) / "spoken.wav"
            subprocess.run(["say", "-v", arguments.me, "-o", str(spoken), "--data-format=LEI16@16000", SAMPLE], check=True)
            with wave.open(str(spoken)) as audio, wave.open(str(sample), "wb") as cut:
                cut.setparams(audio.getparams())
                cut.writeframes(audio.readframes(SAMPLE_SECONDS * RATE))
            command += ["--my-voice", str(sample)]
        output = subprocess.run(command, check=True, capture_output=True, text=True).stdout
    chunks = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
    assert chunks, "no chunks were labelled"
    for chunk in chunks:
        chunk["voice"], chunk["share"] = truth(chunk, turns)
    if arguments.me:
        mine = voices.index(arguments.me)
        total = sum(chunk["duration"] for chunk in chunks)
        right = sum(chunk["duration"] for chunk in chunks if (chunk["final"] == 0) == (chunk["voice"] == mine))
        heard = {voice: sum(chunk["duration"] for chunk in chunks if chunk["voice"] == index) for index, voice in enumerate(voices)}
        print(f"synthetic say voices on the microphone: {', '.join(f'{voice} {seconds:.0f}s' for voice, seconds in heard.items())}; Me profile from a separate {SAMPLE_SECONDS}s {arguments.me} sample")
        print(f"me: {right / total:.0%} of chunk time right about being Me or not, {sum(1 for chunk in chunks if chunk['final'] == 0)} of {len(chunks)} chunks labelled Me, {sum(1 for chunk in chunks if chunk['voice'] == mine)} mostly spoken by {arguments.me}")
        assert right / total > 0.5, "the Me profile did not pick the right voice"
        return
    for chunk in chunks:
        print(f'{chunk["start"]:7.1f}s {chunk["duration"]:5.1f}s  voice {chunk["voice"] + 1} ({chunk["share"]:.0%})  first {chunk["first"]}  live {chunk["live"]}  final {chunk["final"]}  {chunk["seconds"]:.2f}s')
    first, first_labels = accuracy(chunks, "first", len(voices))
    live, live_labels = accuracy(chunks, "live", len(voices))
    final, final_labels = accuracy(chunks, "final", len(voices))
    seconds = [chunk["seconds"] for chunk in chunks]
    mixed = sum(1 for chunk in chunks if chunk["share"] < 0.99)
    print(f"synthetic say voices: {', '.join(voices)}; {len(turns)} turns, {sum(chunk['duration'] for chunk in chunks):.0f}s in {len(chunks)} chunks, {mixed} holding more than one voice; window {arguments.window}s")
    print(f"first: {first:.0%} of chunk time on the right voice as first shown, {first_labels} labels for {len(voices)} voices")
    print(f"live:  {live:.0%} of chunk time on the right voice when the call ends, {live_labels} labels for {len(voices)} voices")
    print(f"final: {final:.0%} of chunk time on the right voice, {final_labels} labels for {len(voices)} voices")
    print(f"seconds per pass: first {seconds[0]:.2f} (loads the models), median {statistics.median(seconds[1:] or seconds):.2f}, max after first {max(seconds[1:] or seconds):.2f}")
    assert live_labels >= 2, "live labels did not separate any voices"


if __name__ == "__main__":
    main()
