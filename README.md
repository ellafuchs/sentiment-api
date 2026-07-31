# Sentiment API

A small web service that reads a sentence and says whether it's **positive** or **negative**.

The point of the project isn't the answer — it's everything around it: which AI model answers is a
setting in a file, and changing that setting is meant to be safe, tested, and reversible.

---

## Run it

You need two terminals.

### Terminal 1 — start the service

```bash
make run
```

It prints a few lines and then **sits there doing nothing**. That's correct — it's waiting for
requests. You'll know it's up when you see `Uvicorn running on http://0.0.0.0:8080`.

Leave this terminal alone. Press `Ctrl+C` when you're done.

### Terminal 2 — ask it something

```bash
uv run python examples/client.py "the ending ruined it for me"
```

```
  NEGATIVE 0.9998  the ending ruined it for me
```

Put any sentence you like in the quotes. Sarcasm and mixed opinions ("great acting, terrible plot")
are where it struggles.

### Or use the browser

Open **http://localhost:8080/docs**

Click the green **POST /predict** bar → **Try it out** → edit the box → **Execute**. The answer
appears below under *Response body*.

That page is generated automatically from the code — nobody wrote any HTML.

---

## Score the model

With the service running in terminal 1:

```bash
make score
```

This sends 200 sentences whose correct answers are already known, then reports how many the model
got right and whether that's good enough to ship.

```
  accuracy       0.9000        90% correct
  macro F1       0.8997        balanced accuracy across both labels
  p95 latency    20.8 ms       95% of requests finished faster than this

✅ Gate passed
```

If a score falls below the limits in `models.yaml`, it says **Gate failed** and names which one.

---

## Run it in a container

A container is a box holding the service, its Python, its libraries **and** the 268 MB model — one
artifact that runs the same anywhere. Cloud Run accepts nothing else.

```bash
make build
```

First time takes about 10 minutes: it downloads torch and the model *inside* the box. After that
it's cached and takes seconds. The image is roughly **1.4 GB** — mostly torch.

```bash
make run-container
```

Same as `make run`, except nothing on your laptop is involved except Docker. Predictions come back
identical — `make score` gives the same 0.9000 accuracy either way.

```bash
make test-container
```

21 checks against the built image, over real HTTP: does it predict correctly, does it reject bad
input, does it honour `$PORT`, **does it still work with no internet at all**, is it running as
root, did any test-only packages sneak in.

That last group is the point. The tests in `tests/` check your *code*. These check the *box* — and
a perfect codebase still ships broken if the weights weren't copied in.

Recorded numbers are in [docs/architecture.md](docs/architecture.md).

---

## The files

| File | What it does | When it runs |
|---|---|---|
| `models.yaml` | Says which AI to use, and the scores it must beat | read at startup |
| `app/fetch.py` | Downloads the AI (255 MB) | once, ever |
| `app/config.py` | Reads `models.yaml` and rejects it if it's wrong | at startup |
| `app/model.py` | Runs the AI: sentence in, label out | startup + every request |
| `app/schemas.py` | Checks requests are valid before the AI sees them | every request |
| `app/main.py` | The web part — receives requests, sends answers | every request |
| `eval/run_eval.py` | Sends the 200 test sentences, records the scores | `make score` |
| `eval/gate.py` | Reads the scores, says pass or fail | `make score` |
| `tests/` | 116 automated checks | `make test` |

The AI itself lives in `.model_cache/` and is **not** in git — 255 MB of numbers doesn't belong in
version control. Git stores the *reference* to the model; the reference is three lines in
`models.yaml`.

---

## Change the model

Edit these lines in `models.yaml`:

```yaml
model:
  source: hf
  id: distilbert-base-uncased-finetuned-sst-2-english
  revision: 714eb0fa89d2f80546fda750413ed43d93601a13
```

Then:

```bash
make fetch
```

```bash
make run
```

`revision` must be the full 40-character commit id, not a branch name. A branch can change under
you; a commit can't. That's what makes "this config" always mean "these exact weights".

Some models name their answers `LABEL_0` and `LABEL_1` instead of `NEGATIVE` and `POSITIVE`. When
that happens the service refuses to start and tells you to add:

```yaml
  labels:
    0: NEGATIVE
    1: POSITIVE
```

Better a clear error at startup than confident nonsense in every answer.

---

## All commands

```bash
make help
```

| | |
|---|---|
| `make install` | Set up the Python environment |
| `make fetch` | Download the AI |
| `make run` | Start the service |
| `make test` | Run the fast tests (~3 seconds) |
| `make test-model` | Run the slow tests that load the real AI |
| `make score` | Grade the model and give a verdict |
| `make lint` | Check code style |
| `make build` | Build the container image |
| `make test-container` | Test the built image over HTTP |
| `make run-container` | Serve from the image, like the cloud will |

---

## Where things stand

- [x] The service runs on your laptop
- [x] 200 test sentences and a pass/fail gate
- [x] Package it into a container
- [ ] Put it on Google Cloud so it has a real web address
- [ ] Make changing the model deploy itself automatically
- [ ] Make it refuse to deploy a worse model
- [ ] Make it faster with a different inference engine
- [ ] Train your own model and run it through the same checks

Everything so far runs entirely on your machine. Nothing is on the internet yet.

---

## One known problem

The model answers **POSITIVE** to *"I would not recommend this to a friend."*

It's wrong, and it's left in on purpose. One of the 25 behaviour checks fails because of it, and
deleting the check to make the tests green would hide a real weakness.

It's also the clearest illustration of why this project exists: the service returns `200 OK` with
99% confidence and is simply wrong. No error, no crash, nothing to alert on. Only a test that
already knows the right answer can catch it.
