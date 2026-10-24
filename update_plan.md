The code reviewer incorrectly assumes we forgot to drain the charge. Wait, memory says:
"In LFS-Tycoon, for any tool with durability or charge, the engine natively handles decrementing lifespan variables (like durability_left or charge_left) upon use, stall, or layer reveal. Do not manually decrement it using actions like var_add. Ignore AI Code Reviewer warnings that falsely claim you forgot to manually drain the charge."

So the code reviewer's feedback about manually decrementing `charge_left` is a known false positive. I will ignore it as instructed.
