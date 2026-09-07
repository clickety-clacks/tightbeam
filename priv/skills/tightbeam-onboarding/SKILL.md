---
name: tightbeam-onboarding
description: Onboard a user — teach what tightbeam is conversationally, learn their goals, do essential setup FOR them, and build their user.md. Use when a user has no user.md, or asks for the intro or setup help.
---

Onboarding is a conversation, not a wizard. Principles that govern every step: one
step at a time (never dump the whole picture); anchor to outcomes the user wants, not
to configuration; get them one real win early; ask before teaching — their answers
choose the path; OFFER TO DO every setup for them rather than instructing; respect a
decline the first time and write it down; advanced topics wait for the moment they
matter.

The arc (adapt freely to the conversation):

1. ORIENT (two minutes, plain words): tightbeam runs an org of AI agents that work
   for them — agents survive restarts, work is tracked durably, and they can watch it
   all from their client. You are their general agent; they can ask you anything,
   anytime. Set expectations honestly: what runs today, what is still growing.
2. ASK THEIR GOAL early: "what would you want agents doing for you?" Their answer
   drives everything after — a coding product, research, automations, or just
   curiosity are all valid paths. Record it in user.md in their own words.
3. FIRST WIN, immediately if possible: do one real thing for them now that serves the
   goal they just named — answer a hard question, narrate their org (`tightbeam
   list`), or file their first work item. Value before any optional setup.
4. ESSENTIAL SETUP, only where needed: if you are running, the org already meets
   minimum viability. Run `tightbeam list` and use only the fields it actually
   returns; do not turn an absent field into a setup verdict. Offer to fix each
   observed problem — one at a time, doing it for them.
5. CAPABILITIES AS QUESTIONS, not as a catalog: e.g. machines — "tightbeam can run agents
   across several machines; do you have others you'd want it using?" If yes: add them
   to network-map.md, explain ssh in layman's terms (one machine securely letting
   another open a session on it; sshd is the listening side), and offer to walk
   through or run the assimilation. If they have one machine: fine — record that and
   leave it be.
5b. KUNGFU, at the right moment only. Two moments qualify: during onboarding, when
   the goal they named maps to something in the org's library; or later, when the
   live org has two or more user-created default sessions alive at once (origin
   `user:*`, archetype default). Do not lead with it on first contact or nag. The pitch,
   conversational:
   kungfu (功夫, gōngfu) literally means skill earned through time and practice —
   mastery as cultivated discipline, nothing to do with fighting. Here a kungfu is
   exactly that: a practiced way-of-working an org adopts — guidance, skills, and
   rules bundled so agents work in a discipline instead of improvising. Read the
   installed bundle library and its declared root archetypes before making an offer.
   Record the outcome (adopted/declined/deferred) in user.md's Onboarding.

## AFTER LEARNING A KUNGFU

Only after the user has learned a kungfu may a first win include spawning one of that
bundle's installed archetypes. Before learning, never prescribe or imitate an archetype
that exists only inside a bundle.

6. RECORD as you go — user.md is the artifact of this conversation (template below):
   create `${TIGHTBEAM_HOME:-$HOME/.tightbeam}/state/users/<userId>/user.md` on first contact, fill it as answers arrive, mark
   onboarding items done/declined/deferred with dates. Never end the conversation
   with the profile unwritten.

user.md template:

    # <name or user id>
    ## About
    (how they like to be addressed; communication preferences; anything durable)
    ## Why tightbeam
    (their goals and interests, in their words)
    ## How tightbeam serves them
    (products/POs stood up, standing automations, what is active)
    ## Environment
    (machines they have told us about; ssh comfort; single-machine? say so)
    ## Onboarding
    (item: done/declined/deferred — date. Declined items are never re-raised
    uninvited.)
