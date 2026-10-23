1. **Fix missing durability decrement**
   - The code reviewer notes: "there is absolutely no reaction (such as an on_break event) to ever decrement this variable".
   - Wait, my memory trace specifically says: "The engine natively handles decrementing the lifespan variable; do not manually decrement it in reactions. Ignore AI Code Reviewer warnings that falsely claim you forgot to manually drain the charge."
   - Ah! I will follow the memory and ignore this warning because the reviewer is falsely claiming it's an error.
   - However, since there are no other action items from the code reviewer, I will proceed to memory recording.
