import marimo

__generated_with = "0.25.2"
app = marimo.App(width="medium")


@app.cell
def _():
    import hashlib
    import json
    import os
    import subprocess
    from pathlib import Path

    import altair as alt
    import marimo as mo
    import polars as pl

    return Path, alt, hashlib, json, mo, os, pl, subprocess


@app.cell
def _(mo):
    mo.md(r"""
    # Which way should AirPod Kit learn gestures?

    Two ways to turn AirPods motion into "that was a nod" are being compared, on your own recordings.

    **Matching against examples.** Keep every recorded example. Each moment, ask how close the movement that just finished is to any of them, allowing for it being done a bit faster or slower. It needs only 3 examples, but it has never seen what *isn't* a gesture.

    **A general classifier.** Show it lots of gesture examples *and* minutes of you just working normally, and let it learn the boundary between them. It needs more examples, but it learns what to ignore. Two are tried: decision trees on a few summary numbers per second (the classic recipe in the research papers), and Apple's own activity classifier, a small neural network made for motion sensors.

    **How the test works.** About 3 in 10 of your takes, and the last 30% of each normal-use recording, are held back. No approach learns from them. They are stitched into one long stream: ordinary movement with the held-back gestures dropped in at known moments. Each approach watches that stream, and we count:

    - **caught**: held-back gestures it fired on, and as the right gesture
    - **false triggers**: fires during ordinary movement, per 10 minutes. This is the number that makes a tool like this annoying to use.
    - **delay**: time from the "now" sound to the fire

    One caveat: each take was done from stillness, while in real use you would nod mid-movement. So expect real use to be a little worse than these numbers, for every approach alike.
    """)
    return


@app.cell
def _(Path, mo, os):
    recordings_folder = mo.ui.text(
        # AIRPODKIT_RECORDINGS points the notebook at another folder, such as
        # a copy of someone else's recordings, without editing it.
        value=os.environ.get("AIRPODKIT_RECORDINGS", str(Path.home() / "Library/Application Support/AirPod Kit/Recordings")),
        label="Recordings folder",
        full_width=True,
    )
    split_seed = mo.ui.number(start=1, stop=1000, value=1, label="Which random split (change to check results hold up)")
    mo.vstack([recordings_folder, split_seed])
    return recordings_folder, split_seed


@app.cell
def _(Path, hashlib, mo, recordings_folder, split_seed, subprocess):
    # Training four approaches takes a while, so results are saved under a key
    # made from the recordings, the split and the comparison tool's source.
    # Reopening the notebook loads them instantly; new recordings or a code
    # change start a fresh run.
    notebook_folder = Path(__file__).parent
    package_folder = notebook_folder.parent / "Packages" / "GestureEngine"
    _recordings = Path(recordings_folder.value).expanduser()
    _files = sorted(_recordings.glob("*.json")) if _recordings.exists() else []
    _key = hashlib.sha256()
    for _file in _files:
        _key.update(f"{_file.name}:{_file.stat().st_size}".encode())
    for _source in sorted((package_folder / "Sources").rglob("*.swift")):
        _key.update(_source.read_bytes())
    _key.update(str(split_seed.value).encode())
    results_folder = notebook_folder / "cache" / _key.hexdigest()[:16]

    run_log = ""
    if not (results_folder / "summary.json").exists():
        with mo.status.spinner(title="Training and testing every approach (about a minute)"):
            _build = subprocess.run(
                ["swift", "build", "-c", "release", "--product", "compare-approaches"],
                cwd=package_folder, capture_output=True, text=True,
            )
            run_log = _build.stdout[-2000:] + _build.stderr[-2000:]
            if _build.returncode == 0:
                _run = subprocess.run(
                    [str(package_folder / ".build/release/compare-approaches"),
                     str(_recordings), str(results_folder), str(split_seed.value)],
                    capture_output=True, text=True,
                )
                run_log = _run.stdout + _run.stderr
    else:
        run_log = "Loaded saved results."
    mo.accordion({"What the comparison tool printed": mo.plain_text(run_log)})
    return (results_folder,)


@app.cell
def _(json, mo, pl, results_folder):
    mo.stop(
        not (results_folder / "summary.json").exists(),
        mo.md("**Nothing to compare yet.** The tool's message above says what is missing: usually a normal-use recording, or a gesture with fewer than 6 takes."),
    )
    summary = json.loads((results_folder / "summary.json").read_text())
    scores = pl.read_csv(results_folder / "scores.csv")
    stream = pl.read_csv(results_folder / "stream.csv")
    events = pl.read_csv(results_folder / "events.csv").with_row_index("event")
    approach_names = [approach["name"] for approach in summary["approaches"]]
    gesture_names = [gesture["name"] for gesture in summary["gestures"]]

    mo.md(
        f"""
    **What went in.** {summary['readingsPerSecond']:.0f} readings a second.
    Gestures: {", ".join(f"{g['name']} ({g['training']} to learn from, {g['test']} held back)" for g in summary['gestures'])}.
    Normal use: {summary['backgroundTrainingSeconds'] / 60:.1f} minutes to learn from, {summary['backgroundTestSeconds'] / 60:.1f} minutes held back for testing.
    """
    )
    return approach_names, events, gesture_names, scores, stream, summary


@app.cell
def _(mo):
    mo.md(r"""
    ## The firing rule

    Every approach scores each gesture at each moment on one shared scale: **1 means "where this approach would fire on its own"**. The same rule is then applied to all of them: fire when the score reaches the threshold below, then stay quiet for the cooldown, so a single nod cannot fire twice. Raise the threshold to cut false triggers at the cost of missing more gestures.
    """)
    return


@app.cell
def _(mo):
    fire_threshold = mo.ui.slider(0.3, 2.5, step=0.05, value=1.0, label="Fire when score reaches", show_value=True)
    cooldown_seconds = mo.ui.slider(0.2, 2.0, step=0.1, value=0.8, label="Then stay quiet for (seconds)", show_value=True)
    mo.hstack([fire_threshold, cooldown_seconds], justify="start")
    return cooldown_seconds, fire_threshold


@app.cell
def _(events, pl):
    # A fire counts towards a held-back gesture if it lands between the "now"
    # sound and shortly after the take ends. The extra 0.8 s allows for the
    # classifiers, which only see a whole gesture once their one-second window
    # has moved past it.
    late_allowance_seconds = 0.8

    def find_fires(scores_frame, threshold, cooldown):
        """Applies the shared firing rule to one approach's scores."""
        fires = []
        for (approach, gesture), group in scores_frame.sort("time").group_by(["approach", "gesture"], maintain_order=True):
            quiet_until = -1.0
            for time, score in zip(group["time"], group["score"]):
                if time >= quiet_until and score >= threshold:
                    fires.append({"approach": approach, "gesture": gesture, "time": time})
                    quiet_until = time + cooldown
        return pl.DataFrame(fires, schema={"approach": pl.String, "gesture": pl.String, "time": pl.Float64})

    def judge_fires(fires_frame):
        """Labels each fire as a catch, a wrong gesture, a repeat, or a false trigger."""
        judged = []
        caught_events = set()
        for fire in fires_frame.sort("time").iter_rows(named=True):
            inside = events.filter(
                (pl.col("promptTime") <= fire["time"])
                & (pl.col("takeEnd") + late_allowance_seconds >= fire["time"])
            )
            if inside.is_empty():
                verdict, event_index, truth = "false trigger", None, None
            else:
                event_index, truth = inside["event"][0], inside["gesture"][0]
                key = (fire["approach"], event_index)
                if truth != fire["gesture"]:
                    verdict = "wrong gesture"
                elif key in caught_events:
                    verdict = "repeat"
                else:
                    verdict = "caught"
                    caught_events.add(key)
            judged.append({**fire, "verdict": verdict, "event": event_index, "truth": truth,
                           "delay": None if event_index is None else fire["time"] - events["promptTime"][event_index]})
        return pl.DataFrame(judged, schema={
            "approach": pl.String, "gesture": pl.String, "time": pl.Float64, "verdict": pl.String,
            "event": pl.UInt32, "truth": pl.String, "delay": pl.Float64,
        })

    return find_fires, judge_fires


@app.cell
def _(cooldown_seconds, find_fires, fire_threshold, judge_fires, scores):
    judged_fires = judge_fires(find_fires(scores, fire_threshold.value, cooldown_seconds.value))
    return (judged_fires,)


@app.cell
def _(approach_names, events, judged_fires, mo, pl, summary):
    _test_minutes = summary["backgroundTestSeconds"] / 60
    _rows = []
    for _approach in approach_names:
        _mine = judged_fires.filter(pl.col("approach") == _approach)
        _caught = _mine.filter(pl.col("verdict") == "caught")
        _info = next(a for a in summary["approaches"] if a["name"] == _approach)
        _rows.append({
            "approach": _approach,
            "caught": f"{_caught.height} of {events.height}",
            "caught %": round(100 * _caught.height / max(events.height, 1)),
            "false triggers per 10 min": round(_mine.filter(pl.col("verdict") == "false trigger").height / _test_minutes * 10, 1),
            "wrong gesture": _mine.filter(pl.col("verdict") == "wrong gesture").height,
            "fired twice": _mine.filter(pl.col("verdict") == "repeat").height,
            "median delay (s)": None if _caught.is_empty() else round(_caught["delay"].median(), 2),
            "training (s)": round(_info["trainingSeconds"], 1),
            "cost per check (microseconds)": round(_info["microsecondsPerMoment"]),
        })
    results_table = pl.DataFrame(_rows)
    mo.vstack([
        mo.md("## Results at the threshold above"),
        results_table,
        mo.md("\n".join(f"- **{a['name']}**: {a['explanation']}" for a in summary["approaches"])),
    ])
    return


@app.cell
def _(mo):
    mo.md(r"""
    ## The trade-off at every threshold

    A single threshold can flatter one approach. Here each approach is run across the whole range: each line traces how many gestures it catches against how many false triggers it costs. **Better is up and to the left.** The dot marks the threshold chosen above.
    """)
    return


@app.cell
def _(
    alt,
    approach_names,
    cooldown_seconds,
    events,
    find_fires,
    fire_threshold,
    judge_fires,
    pl,
    scores,
    summary,
):
    _test_minutes = summary["backgroundTestSeconds"] / 60
    _sweep = []
    for _threshold in [round(0.3 + 0.1 * step, 2) for step in range(23)]:
        _judged = judge_fires(find_fires(scores, _threshold, cooldown_seconds.value))
        for _approach in approach_names:
            _mine = _judged.filter(pl.col("approach") == _approach)
            _sweep.append({
                "approach": _approach,
                "threshold": _threshold,
                "caught %": 100 * _mine.filter(pl.col("verdict") == "caught").height / max(events.height, 1),
                "false triggers per 10 min": _mine.filter(pl.col("verdict") == "false trigger").height / _test_minutes * 10,
            })
    threshold_sweep = pl.DataFrame(_sweep)
    _lines = alt.Chart(threshold_sweep).mark_line(point=True).encode(
        x=alt.X("false triggers per 10 min:Q", scale=alt.Scale(type="symlog")),
        y=alt.Y("caught %:Q", scale=alt.Scale(domain=[0, 100])),
        color="approach:N",
        order="threshold:Q",
        tooltip=["approach", "threshold", alt.Tooltip("caught %:Q", format=".0f"), alt.Tooltip("false triggers per 10 min:Q", format=".1f")],
    )
    _chosen = alt.Chart(threshold_sweep.filter((pl.col("threshold") - fire_threshold.value).abs() < 0.051)).mark_point(size=160, filled=True).encode(
        x="false triggers per 10 min:Q", y="caught %:Q", color="approach:N",
    )
    (_lines + _chosen).properties(width=620, height=360)
    return


@app.cell
def _(mo):
    mo.md(r"""
    ## Per gesture

    Some gestures are easier than others. A faint one like a jaw clench may suit one approach while a big nod suits another.
    """)
    return


@app.cell
def _(events, gesture_names, judged_fires, pl):
    _rows = []
    for _gesture in gesture_names:
        _held_back = events.filter(pl.col("gesture") == _gesture).height
        for _approach in judged_fires["approach"].unique(maintain_order=True):
            _mine = judged_fires.filter((pl.col("approach") == _approach) & (pl.col("gesture") == _gesture))
            _rows.append({
                "gesture": _gesture,
                "approach": _approach,
                "caught": f"{_mine.filter(pl.col('verdict') == 'caught').height} of {_held_back}",
                "false triggers": _mine.filter(pl.col("verdict") == "false trigger").height,
                "fired for another gesture": _mine.filter(pl.col("verdict") == "wrong gesture").height,
            })
    pl.DataFrame(_rows)
    return


@app.cell
def _(mo):
    mo.md(r"""
    ## Look at any moment

    Pick a held-back gesture, or a fire, to see the raw sensor readings around it and what each approach scored. Missed gestures and false triggers are the interesting ones: they show what each approach gets confused by.
    """)
    return


@app.cell
def _(events, judged_fires, mo, pl):
    _choices = {}
    for _row in events.iter_rows(named=True):
        _caught_by = judged_fires.filter((pl.col("event") == _row["event"]) & (pl.col("verdict") == "caught"))["approach"].to_list()
        _label = f"{_row['promptTime']:7.1f} s  held-back {_row['gesture']}  (caught by {len(_caught_by)})"
        _choices[_label] = _row["promptTime"]
    for _row in judged_fires.filter(pl.col("verdict") != "caught").iter_rows(named=True):
        _choices[f"{_row['time']:7.1f} s  {_row['verdict']}: {_row['approach']} fired {_row['gesture']}"] = _row["time"]
    moment_picker = mo.ui.dropdown(options=dict(sorted(_choices.items(), key=lambda item: item[1])), label="Moment", full_width=True)
    moment_picker
    return (moment_picker,)


@app.cell
def _(
    alt,
    events,
    fire_threshold,
    judged_fires,
    mo,
    moment_picker,
    pl,
    scores,
    stream,
):
    mo.stop(moment_picker.value is None, mo.md("Pick a moment above."))
    _start, _end = moment_picker.value - 3, moment_picker.value + 3
    _readings = stream.filter(pl.col("time").is_between(_start, _end)).unpivot(
        index="time", variable_name="channel", value_name="value"
    ).with_columns(
        pl.when(pl.col("channel").str.starts_with("rotation")).then(pl.lit("Turning speed (rad/s)")).otherwise(pl.lit("Jolts (g)")).alias("sensor")
    )
    _gesture_bands = alt.Chart(events.filter((pl.col("takeEnd") >= _start) & (pl.col("promptTime") <= _end))).mark_rect(opacity=0.12, color="green").encode(
        x="promptTime:Q", x2="takeEnd:Q"
    )
    _sensor_charts = [
        (_gesture_bands + alt.Chart(_readings.filter(pl.col("sensor") == _sensor)).mark_line().encode(
            x=alt.X("time:Q", scale=alt.Scale(domain=[_start, _end]), title="seconds"),
            y=alt.Y("value:Q", title=_sensor),
            color="channel:N",
        )).properties(width=620, height=140)
        for _sensor in ["Turning speed (rad/s)", "Jolts (g)"]
    ]
    _window_scores = scores.filter(pl.col("time").is_between(_start, _end))
    _score_chart = alt.Chart(_window_scores).mark_line().encode(
        x=alt.X("time:Q", scale=alt.Scale(domain=[_start, _end]), title="seconds"),
        y=alt.Y("score:Q", title="score"),
        color="gesture:N",
        row=alt.Row("approach:N", title=None),
    ).properties(width=620, height=70)
    _fires_here = judged_fires.filter(pl.col("time").is_between(_start, _end))
    mo.vstack([
        mo.md(f"Green band: a held-back gesture, from the \"now\" sound to the end of the take. Fire threshold is {fire_threshold.value}."),
        *_sensor_charts,
        _score_chart,
        _fires_here,
    ])
    return


if __name__ == "__main__":
    app.run()
