------------------------------ MODULE ImageStore ------------------------------
(***************************************************************************)
(* How a libfx session saves its images: each image once, in the host's   *)
(* store, named by the hash of its bytes, while the session's records and  *)
(* checkpoints hold only the name.                                         *)
(*                                                                         *)
(* A prompt's image goes to the store first and the prompt is sent only    *)
(* once the write landed; with StoreFirst = FALSE it is sent while the     *)
(* write is in flight (ImageStore-SendBeforeStore.cfg). With Durable the   *)
(* prompt is stored in the session's log after its image, naming it, and   *)
(* the worker resolves the name before it runs the turn.                   *)
(*                                                                         *)
(* A turn's first record names its image. A checkpoint writes the whole    *)
(* history again: it names the images the core knows are stored and keeps *)
(* the rest inline. With Old the session starts with an image an older     *)
(* libfx saved inline, which the store never held; with MarkOnlyStored =   *)
(* FALSE a checkpoint names it anyway (ImageStore-NameUnstored.cfg).       *)
(*                                                                         *)
(* A durable caller may retry a prompt the log already holds, under its    *)
(* messageId, carrying any image. The retry stores nothing: the log keeps  *)
(* the input it holds and drops the retry's. With DropRepeats = FALSE the  *)
(* retry's input lands too, naming an image the store may never have got   *)
(* (ImageStore-RetryLands.cfg).                                            *)
(*                                                                         *)
(* The core may crash, losing what it held and the image writes in flight. *)
(* It opens again in two phases: it names the images it needs, the host    *)
(* stages each from its store, then the core opens. An image the store     *)
(* lost fails the open; with FailOnMissing = FALSE the open drops it       *)
(* (ImageStore-DropMissing.cfg).                                           *)
(*                                                                         *)
(* `act` names each step and its arguments, so a driver can replay any     *)
(* path of the state graph against the real code.                          *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    N,              \* prompts the caller makes, at most
    Imgs,           \* images a prompt may carry; equal images share a name
    Old,            \* whether the session starts with an image saved inline
    Durable,        \* whether prompts pass through a durable session's log
    MaxFaults,      \* bound on failed image writes
    MaxCrashes,     \* bound on crashes of the core
    MaxLoss,        \* bound on images the store loses
    StoreFirst,     \* whether a prompt is sent only after its image is stored
    MarkOnlyStored, \* whether the core names only images it knows are stored
    FailOnMissing,  \* whether an open that misses an image fails
    MaxRetries,     \* bound on retries of prompts the log holds
    DropRepeats     \* whether the log drops a retried prompt's input

ASSUME N \in Nat /\ MaxFaults \in Nat /\ MaxCrashes \in Nat /\ MaxLoss \in Nat
ASSUME Old \in BOOLEAN /\ Durable \in BOOLEAN /\ StoreFirst \in BOOLEAN
ASSUME MarkOnlyStored \in BOOLEAN /\ FailOnMissing \in BOOLEAN
ASSUME MaxRetries \in Nat /\ DropRepeats \in BOOLEAN
ASSUME "o" \notin Imgs

Prompts == 1..N
None == "none"
OldImg == "o"
AllImgs == Imgs \cup {OldImg}
Phases == {"unmade", "putting", "put", "queued", "sent", "started", "ended", "failed", "lost"}
CoreStates == {"open", "down", "opening", "failed"}

VARIABLES
    made,      \* how many prompts the caller has made
    img,       \* each prompt's image
    ph,        \* where each prompt is
    putting,   \* the prompts whose image write is in flight
    store,     \* the images the host's store holds
    lostImgs,  \* the images the store lost
    saved,     \* the saved history: each turn's image, named or inline
    inputs,    \* with Durable: the prompts the log holds, in the order they landed
    mem,       \* the core's history while it runs: each image, and whether it is known stored
    up,        \* the core: open, down, opening, or failed to open
    staged,    \* the images staged for the open in progress
    dirty,     \* whether records landed since the last checkpoint
    faults,    \* failed image writes so far
    crashes,   \* crashes so far
    retries,   \* retries so far
    repeats,   \* the images retried inputs that landed in the log name
    act        \* the last step and its arguments

vars == <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats, act>>

TypeOK ==
    /\ made \in 0..N
    /\ img \in [Prompts -> Imgs \cup {None}]
    /\ ph \in [Prompts -> Phases]
    /\ putting \subseteq Prompts
    /\ store \subseteq AllImgs
    /\ lostImgs \subseteq AllImgs
    /\ saved \in Seq([i : AllImgs, ref : BOOLEAN])
    /\ inputs \in Seq(Prompts)
    /\ mem \in Seq([i : AllImgs, stored : BOOLEAN])
    /\ up \in CoreStates
    /\ staged \subseteq AllImgs
    /\ dirty \in BOOLEAN
    /\ faults \in 0..MaxFaults
    /\ crashes \in 0..MaxCrashes
    /\ retries \in 0..MaxRetries
    /\ repeats \subseteq Imgs

Init ==
    /\ made = 0
    /\ img = [p \in Prompts |-> None]
    /\ ph = [p \in Prompts |-> "unmade"]
    /\ putting = {}
    /\ store = {}
    /\ lostImgs = {}
    /\ saved = IF Old THEN << [i |-> OldImg, ref |-> FALSE] >> ELSE << >>
    /\ inputs = << >>
    /\ mem = << >>
    /\ up = "down"
    /\ staged = {}
    /\ dirty = FALSE
    /\ faults = 0
    /\ crashes = 0
    /\ retries = 0
    /\ repeats = {}
    /\ act = << "Init" >>

\* The images the saved history names.
Named == {saved[k].i : k \in {j \in 1..Len(saved) : saved[j].ref}}
Images(s) == [k \in 1..Len(s) |-> s[k].i]
Running == \E p \in Prompts : ph[p] \in {"sent", "started"}
Queued(p) == \E k \in 1..Len(inputs) : inputs[k] = p
\* The prompt the worker takes next: the first in the log it has not taken.
NextInput(p) ==
    /\ ph[p] = "queued"
    /\ \E k \in 1..Len(inputs) :
        /\ inputs[k] = p
        /\ \A j \in 1..(k - 1) : ph[inputs[j]] # "queued"

Set(f, p, v) == [f EXCEPT ![p] = v]

----------------------------------------------------------------------------
\* The caller

\* A prompt carrying image i. A plain engine takes prompts only while open.
Make(p, i) ==
    /\ made + 1 = p
    /\ Durable \/ up = "open"
    /\ made' = p
    /\ img' = Set(img, p, i)
    /\ ph' = Set(ph, p, "putting")
    /\ putting' = putting \cup {p}
    /\ act' = << "Make", p, i >>
    /\ UNCHANGED <<store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats>>

\* The prompt's image write lands in the store.
PutLand(p) ==
    /\ p \in putting
    /\ store' = store \cup {img[p]}
    /\ putting' = putting \ {p}
    /\ ph' = IF ph[p] = "putting" THEN Set(ph, p, "put") ELSE ph
    /\ act' = << "PutLand", p >>
    /\ UNCHANGED <<made, img, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats>>

\* The write fails. A prompt not yet sent fails with it; one sent early
\* (StoreFirst = FALSE) goes on naming an image the store never got.
PutFail(p) ==
    /\ p \in putting
    /\ faults < MaxFaults
    /\ faults' = faults + 1
    /\ putting' = putting \ {p}
    /\ ph' = IF ph[p] = "putting" THEN Set(ph, p, "failed") ELSE ph
    /\ act' = << "PutFail", p >>
    /\ UNCHANGED <<made, img, store, lostImgs, saved, inputs, mem, up, staged, dirty, crashes, retries, repeats>>

----------------------------------------------------------------------------
\* The host and the core

\* A plain engine sends a prompt once its image is stored.
Send(p) ==
    /\ ~Durable
    /\ up = "open"
    /\ ~Running
    /\ IF StoreFirst THEN ph[p] = "put" ELSE ph[p] \in {"putting", "put"}
    /\ ph' = Set(ph, p, "sent")
    /\ act' = << "Send", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats>>

\* A durable prompt lands in the log after its image, naming it.
Enqueue(p) ==
    /\ Durable
    /\ ph[p] = "put"
    /\ inputs' = Append(inputs, p)
    /\ ph' = Set(ph, p, "queued")
    /\ act' = << "Enqueue", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, mem, up, staged, dirty, faults, crashes, retries, repeats>>

\* The worker takes the next prompt and resolves its image's name. An
\* image the store lost fails the turn.
Take(p) ==
    /\ Durable
    /\ up = "open"
    /\ ~Running
    /\ NextInput(p)
    /\ ph' = Set(ph, p, IF img[p] \in store THEN "sent" ELSE "failed")
    /\ act' = << "Take", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats>>

\* The turn's first record lands, naming the image the host stored.
TurnStart(p) ==
    /\ ph[p] = "sent"
    /\ up = "open"
    /\ mem' = Append(mem, [i |-> img[p], stored |-> TRUE])
    /\ saved' = Append(saved, [i |-> img[p], ref |-> TRUE])
    /\ dirty' = TRUE
    /\ ph' = Set(ph, p, "started")
    /\ act' = << "TurnStart", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, inputs, up, staged, faults, crashes, retries, repeats>>

\* The model answers and the turn ends.
TurnEnd(p) ==
    /\ ph[p] = "started"
    /\ up = "open"
    /\ ph' = Set(ph, p, "ended")
    /\ dirty' = TRUE
    /\ act' = << "TurnEnd", p >>
    /\ UNCHANGED <<made, img, putting, store, lostImgs, saved, inputs, mem, up, staged, faults, crashes, retries, repeats>>

\* A checkpoint between turns writes the history again from the core.
Checkpoint ==
    /\ up = "open"
    /\ dirty
    /\ ~Running
    /\ saved' = [k \in 1..Len(mem) |-> [i |-> mem[k].i, ref |-> mem[k].stored \/ ~MarkOnlyStored]]
    /\ dirty' = FALSE
    /\ act' = << "Checkpoint" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, inputs, mem, up, staged, faults, crashes, retries, repeats>>

\* The core crashes: it loses what it held and every write in flight. A
\* prompt not yet in the log or not yet started is lost to a plain engine;
\* a durable one stays in the log and runs again.
Crash ==
    /\ crashes < MaxCrashes
    /\ up \in {"open", "opening"}
    /\ crashes' = crashes + 1
    /\ up' = "down"
    /\ mem' = << >>
    /\ staged' = {}
    /\ putting' = {}
    /\ ph' = [p \in Prompts |->
                CASE ph[p] \in {"putting", "put"} -> "lost"
                  [] ph[p] = "sent" -> IF Durable THEN "queued" ELSE "lost"
                  [] OTHER -> ph[p]]
    /\ act' = << "Crash" >>
    /\ UNCHANGED <<made, img, store, lostImgs, saved, inputs, dirty, faults, retries, repeats>>

\* Opening, first phase: the core reads the saved history and names the
\* images it does not hold.
OpenBegin ==
    /\ up = "down"
    /\ up' = "opening"
    /\ staged' = {}
    /\ act' = << "OpenBegin" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, dirty, faults, crashes, retries, repeats>>

\* The host stages one named image from its store.
Stage(i) ==
    /\ up = "opening"
    /\ i \in Named \ staged
    /\ i \in store
    /\ staged' = staged \cup {i}
    /\ act' = << "Stage", i >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, dirty, faults, crashes, retries, repeats>>

\* A named image the store does not hold fails the open.
OpenMissing ==
    /\ up = "opening"
    /\ FailOnMissing
    /\ \E i \in Named \ staged : i \notin store
    /\ up' = "failed"
    /\ act' = << "OpenMissing" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, staged, dirty, faults, crashes, retries, repeats>>

\* Opening, second phase: every named image is staged, and the core holds
\* the saved history again. With FailOnMissing = FALSE an image the store
\* lost is dropped.
OpenOk ==
    /\ up = "opening"
    /\ \/ Named \subseteq staged
       \/ ~FailOnMissing /\ \A i \in Named \ staged : i \notin store
    /\ LET kept == SelectSeq(saved, LAMBDA e : ~e.ref \/ e.i \in staged)
       IN mem' = [k \in 1..Len(kept) |-> [i |-> kept[k].i, stored |-> kept[k].ref]]
    /\ up' = "open"
    /\ staged' = {}
    /\ act' = << "OpenOk" >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, dirty, faults, crashes, retries, repeats>>

\* A retry of prompt p, which the log holds, under its messageId, carrying
\* image i. It stores nothing; the log drops its input, or with DropRepeats
\* = FALSE keeps it, naming i.
Retry(p, i) ==
    /\ Durable
    /\ retries < MaxRetries
    /\ Queued(p)
    /\ retries' = retries + 1
    /\ repeats' = IF DropRepeats THEN repeats ELSE repeats \cup {i}
    /\ act' = << "Retry", p, i >>
    /\ UNCHANGED <<made, img, ph, putting, store, lostImgs, saved, inputs, mem, up, staged, dirty, faults, crashes>>

\* The store loses an image: corruption, or an operator deleting it.
Lose(i) ==
    /\ Cardinality(lostImgs) < MaxLoss
    /\ i \in store
    /\ store' = store \ {i}
    /\ lostImgs' = lostImgs \cup {i}
    /\ act' = << "Lose", i >>
    /\ UNCHANGED <<made, img, ph, putting, saved, inputs, mem, up, staged, dirty, faults, crashes, retries, repeats>>

\* Nothing is left to do: every prompt settled, or the open failed.
Finished ==
    \/ up = "failed"
    \/ /\ up = "open"
       /\ made = N
       /\ putting = {}
       /\ ~dirty
       /\ \A p \in Prompts : ph[p] \in {"ended", "failed", "lost"}

Done == Finished /\ UNCHANGED vars

Next ==
    \/ \E p \in Prompts, i \in Imgs : Make(p, i)
    \/ \E p \in Prompts : PutLand(p) \/ PutFail(p) \/ Send(p) \/ Enqueue(p) \/ Take(p) \/ TurnStart(p) \/ TurnEnd(p)
    \/ Checkpoint
    \/ Crash
    \/ OpenBegin
    \/ \E i \in AllImgs : Stage(i)
    \/ OpenMissing
    \/ OpenOk
    \/ \E i \in AllImgs : Lose(i)
    \/ \E p \in Prompts, i \in Imgs : Retry(p, i)
    \/ Done

Spec == Init /\ [][Next]_vars

\* The paths sdk/tests/model/drive-images.mjs takes against a plain engine
\* (Durable = FALSE). The engine runs one prompt at a time, so a prompt is
\* made only when none is in flight. The code takes the steps in Auto on its
\* own as soon as it can, so the driver moves only when none of them can.
Idle == \A p \in Prompts : ph[p] \notin {"putting", "put", "sent", "started"}
Auto ==
    \/ \E p \in Prompts : Send(p) \/ TurnStart(p)
    \/ Checkpoint
    \/ \E i \in AllImgs : Stage(i)
    \/ OpenMissing
    \/ OpenOk
Quiet == ~ENABLED Auto
DriverStep ==
    \/ \E p \in Prompts, i \in Imgs : Idle /\ Make(p, i)
    \/ \E p \in Prompts : PutLand(p) \/ PutFail(p) \/ TurnEnd(p)
    \/ Crash
    \/ OpenBegin
    \/ \E i \in AllImgs : Lose(i)
DriveSpec == Init /\ [][(Quiet /\ DriverStep) \/ Auto \/ Done]_vars

----------------------------------------------------------------------------
\* What must hold

\* Nothing saved names an image the store does not hold, unless the store
\* lost it.
NoDanglingRef ==
    lostImgs = {} =>
        /\ Named \subseteq store
        /\ Durable => \A k \in 1..Len(inputs) : img[inputs[k]] \in store
        /\ repeats \subseteq store

\* Only the image an older libfx saved inline is ever saved inline.
OneCopy == \A k \in 1..Len(saved) : ~saved[k].ref => saved[k].i = OldImg

\* An open core holds exactly the saved history's images, in order.
OpenExact == up = "open" => Images(mem) = Images(saved)

\* What the core counts as stored is stored, unless the store lost it.
KnownStoredIsStored ==
    (lostImgs = {} /\ up = "open") => \A k \in 1..Len(mem) : mem[k].stored => mem[k].i \in store

\* An open fails only when the store lost an image.
FailsOnlyOnLoss == up = "failed" => lostImgs # {}

=============================================================================
