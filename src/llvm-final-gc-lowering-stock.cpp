// This file is a part of Julia. License is MIT: https://julialang.org/license

#include "llvm-gc-interface-passes.h"

#define DEBUG_TYPE "final_gc_lowering"
STATISTIC(GCAllocBytesCount, "Number of lowered GCAllocBytesFunc intrinsics");
STATISTIC(GCInlinePoolAllocCount, "Number of inlined pool allocation fast paths");

// Experimental knobs, read once from the environment:
//   JULIA_INLINE_POOL_ALLOC=0            always call jl_gc_small_alloc
//   JULIA_INLINE_POOL_ALLOC_SAFEPOINT=0  no safepoint poll on the fast path
//   JULIA_INLINE_POOL_ALLOC_NEWPAGES=0   only pop the freelist inline
//   JULIA_INLINE_POOL_ALLOC_COLD=1       inline at cold sites too (see `isColdAllocSite`)
static bool envFlag(const char *name, bool dflt)
{
    const char *s = getenv(name);
    return s ? strcmp(s, "0") != 0 : dflt;
}

// Allocations that are followed by a noreturn call or `unreachable` in their block (e.g.
// building an exception to throw) or in cold/size-optimized functions keep the plain call.
static bool isColdAllocSite(CallInst *target)
{
    Function *F = target->getFunction();
    if (F->hasFnAttribute(Attribute::Cold) || F->hasOptSize())
        return true;
    for (Instruction *I = target->getNextNode(); I; I = I->getNextNode()) {
        if (isa<UnreachableInst>(I))
            return true;
        if (auto CI = dyn_cast<CallBase>(I))
            if (CI->doesNotReturn())
                return true;
    }
    return false;
}

#if !defined(MEMDEBUG) && !defined(GC_DEBUG_ENV) && !defined(_COMPILER_MSAN_ENABLED_)
#define JL_INLINE_POOL_ALLOC_SUPPORTED
#endif

// Emit the common case of `jl_gc_small_alloc_inner` inline: pop the pool's freelist or
// bump its `newpages` cursor within the current page, count the allocation, and call into
// the runtime only when the freelist changes page, the page is exhausted, or the
// allocation profiler is on. The heap-target check (`maybe_collect`) is left to the slow
// path: pool allocations only grow the heap when a page is added, which is a slow-path
// event, so a collection is at most one page late.
//
// If `resetTag` is set the site may run with a cancellation reset region published, and a
// delivered reset may abandon the object between any two instructions. The commit of the
// pop/bump is a single store, so the pool state stays consistent. An abandoned freelist
// object keeps the old link as its header (an unmarked, untagged cell to the sweep); a cell
// bumped from `newpages` has whatever the page held before, so it gets `resetTag` as its
// header before the commit, as `jl_gc_small_alloc_reset_safe` does. A reset between the
// commit and the `nalloc` bump leaves the object uncounted (the sweep still frees it), so
// the allocation statistics can drift by one object per such reset.
static Value *emitInlinePoolAlloc(IRBuilder<> &builder, Type *T_size, CallInst *target,
                                  Value *ptls, int offset, int osize, bool safepoint,
                                  bool newpages, Value *resetTag, CallInst *slowCall)
{
    LLVMContext &C = builder.getContext();
    Function *F = target->getFunction();
    Type *T_i8 = Type::getInt8Ty(C);
    Type *T_i64 = Type::getInt64Ty(C);
    Type *T_ptr = PointerType::get(C, 0);
    MDBuilder MDB(C);
    auto unlikely = MDB.createUnlikelyBranchWeights();
    const uint64_t page_lg2 = jl_gc_pool_page_lg2();
    const uint64_t page_sz = (uint64_t)1 << page_lg2;
    auto i8gep = [&](Value *base, int64_t off, const Twine &name = "") {
        return builder.CreateConstInBoundsGEP1_64(T_i8, base, off, name);
    };
    auto relaxedLoad = [&](Type *T, Value *addr, const Twine &name = "") {
        auto ld = builder.CreateAlignedLoad(T, addr, Align(sizeof(void*)), name);
        ld->setOrdering(AtomicOrdering::Monotonic);
        return ld;
    };
    auto relaxedStore = [&](Value *v, Value *addr) {
        auto st = builder.CreateAlignedStore(v, addr, Align(sizeof(void*)));
        st->setOrdering(AtomicOrdering::Monotonic);
        return st;
    };

    BasicBlock *entry = target->getParent();
    BasicBlock *cont = entry->splitBasicBlock(target, "pool_alloc.cont");
    entry->getTerminator()->eraseFromParent();
    auto mkBB = [&](const char *name) { return BasicBlock::Create(C, name, F, cont); };
    BasicBlock *flBB = mkBB("pool_alloc.freelist");
    BasicBlock *flPopBB = mkBB("pool_alloc.freelist_pop");
    BasicBlock *npBB = newpages ? mkBB("pool_alloc.newpages") : nullptr;
    BasicBlock *npBumpBB = newpages ? mkBB("pool_alloc.newpages_bump") : nullptr;
    BasicBlock *npTagBB = newpages && resetTag ? mkBB("pool_alloc.newpages_tag") : nullptr;
    BasicBlock *fastBB = mkBB("pool_alloc.fast");
    BasicBlock *slowBB = mkBB("pool_alloc.slow");

    // entry: safepoint poll, then bail out to the runtime if the allocation profiler is on
    builder.SetInsertPoint(entry);
    if (safepoint)
        emit_gc_safepoint(builder, T_size, ptls, nullptr, true);
    auto prof = relaxedLoad(T_i8,
        i8gep(ptls, offsetof(jl_tls_states_t, gc_tls_common) +
                    offsetof(jl_gc_tls_states_common_t, alloc_profile_enabled)), "alloc_profile");
    cast<LoadInst>(prof)->setAlignment(Align(1));
    builder.CreateCondBr(builder.CreateICmpNE(prof, ConstantInt::get(T_i8, 0)), slowBB, flBB, unlikely);

    // freelist: v = p->freelist; if v == NULL try newpages
    builder.SetInsertPoint(flBB);
    Value *pool = i8gep(ptls, offset, "pool");
    Value *pfreelist = i8gep(pool, offsetof(jl_gc_pool_t, freelist));
    Value *flv = relaxedLoad(T_ptr, pfreelist, "freelist");
    builder.CreateCondBr(builder.CreateIsNull(flv), newpages ? npBB : slowBB, flPopBB, unlikely);

    // freelist_pop: next = v->next; the runtime updates page metadata when the freelist
    // moves to another page (including next == NULL), so leave that case to it
    builder.SetInsertPoint(flPopBB);
    Value *next = relaxedLoad(T_ptr, flv, "freelist.next");
    Value *crosses = builder.CreateICmpUGE(
        builder.CreateXor(builder.CreatePtrToInt(flv, T_size), builder.CreatePtrToInt(next, T_size)),
        ConstantInt::get(T_size, page_sz));
    builder.CreateCondBr(crosses, slowBB, fastBB, unlikely);

    Value *npv = nullptr, *pnewpages = nullptr, *npNext = nullptr;
    if (newpages) {
        // newpages: v = p->newpages; bump within the page `v - 1` lies in
        builder.SetInsertPoint(npBB);
        pnewpages = i8gep(pool, offsetof(jl_gc_pool_t, newpages));
        npv = relaxedLoad(T_ptr, pnewpages, "newpages");
        builder.CreateCondBr(builder.CreateIsNull(npv), slowBB, npBumpBB, unlikely);
        builder.SetInsertPoint(npBumpBB);
        Value *npInt = builder.CreatePtrToInt(npv, T_size);
        Value *npNextInt = builder.CreateAdd(npInt, ConstantInt::get(T_size, osize));
        Value *pageEnd = builder.CreateAdd(
            builder.CreateAnd(builder.CreateSub(npInt, ConstantInt::get(T_size, 1)),
                              ConstantInt::get(T_size, ~(page_sz - 1))),
            ConstantInt::get(T_size, page_sz));
        npNext = builder.CreateGEP(T_i8, npv, ConstantInt::get(T_size, osize));
        builder.CreateCondBr(builder.CreateICmpULT(pageEnd, npNextInt), slowBB,
                             npTagBB ? npTagBB : fastBB, unlikely);
        if (npTagBB) {
            builder.SetInsertPoint(npTagBB);
            Value *tag = resetTag->getType()->isPointerTy()
                ? builder.CreatePtrToInt(builder.CreateAddrSpaceCast(resetTag, T_ptr), T_size)
                : builder.CreateZExtOrTrunc(resetTag, T_size);
            builder.CreateAlignedStore(tag, npv, Align(sizeof(void*)));
            // a reset is delivered by a signal handler on this thread
            builder.CreateFence(AtomicOrdering::Release, SyncScope::SingleThread);
            builder.CreateBr(fastBB);
        }
    }

    // fast: commit the pop/bump, update the per-thread counters and return the object
    builder.SetInsertPoint(fastBB);
    PHINode *tagged = builder.CreatePHI(T_ptr, 2, "pool_alloc.tagged");
    PHINode *slot = builder.CreatePHI(T_ptr, 2, "pool_alloc.slot");
    PHINode *slotVal = builder.CreatePHI(T_ptr, 2, "pool_alloc.next");
    tagged->addIncoming(flv, flPopBB);
    slot->addIncoming(pfreelist, flPopBB);
    slotVal->addIncoming(next, flPopBB);
    if (newpages) {
        BasicBlock *npPred = npTagBB ? npTagBB : npBumpBB;
        tagged->addIncoming(npv, npPred);
        slot->addIncoming(pnewpages, npPred);
        slotVal->addIncoming(npNext, npPred);
    }
    relaxedStore(slotVal, slot);
    // p->nalloc += 1 (folded into the thread's `gc_num` counters by the runtime)
    Value *pnalloc = i8gep(pool, offsetof(jl_gc_pool_t, nalloc));
    auto nalloc = relaxedLoad(T_i64, pnalloc, "nalloc");
    nalloc->setAlignment(Align(alignof(int64_t)));
    relaxedStore(builder.CreateAdd(nalloc, ConstantInt::get(T_i64, 1)), pnalloc)
        ->setAlignment(Align(alignof(int64_t)));
    Value *fastV = builder.CreateAddrSpaceCast(
        builder.CreateConstInBoundsGEP1_64(T_i8, tagged, sizeof(jl_taggedvalue_t)),
        target->getType());
    builder.CreateBr(cont);

    // slow: the runtime entry point redoes everything, including maybe_collect
    builder.SetInsertPoint(slowBB);
    slowCall->insertInto(slowBB, slowBB->end());
    builder.CreateBr(cont);

    builder.SetInsertPoint(target);
    PHINode *res = builder.CreatePHI(target->getType(), 2);
    res->addIncoming(fastV, fastBB);
    res->addIncoming(slowCall, slowBB);
    ++GCInlinePoolAllocCount;
    return res;
}

Value* FinalLowerGC::lowerGCAllocBytes(CallInst *target, Function &F)
{
    ++GCAllocBytesCount;
    CallInst *newI;

    IRBuilder<> builder(target);
    auto ptls = target->getArgOperand(0);
    auto type = target->getArgOperand(2);
    // Sites that may execute with a cancellation reset region published
    // (annotated by CancellationLowering) allocate through the reset-safe
    // entry points, which unpublish/republish the region themselves.
    bool resetSafe = target->hasMetadata("julia.reset_region");
    uint64_t derefBytes = 0;
    if (auto CI = dyn_cast<ConstantInt>(target->getArgOperand(1))) {
        size_t sz = (size_t)CI->getZExtValue();
        // This is strongly architecture and OS dependent
        int osize;
        int offset = jl_gc_classify_pools(sz, &osize);
        if (offset < 0) {
            newI = builder.CreateCall(
                resetSafe ? bigAllocResetSafeFunc : bigAllocFunc,
                { ptls, ConstantInt::get(T_size, sz + sizeof(void*)), type });
            if (sz > 0)
                derefBytes = sz;
        }
        else {
            auto pool_offs = ConstantInt::get(Type::getInt32Ty(F.getContext()), offset);
            auto pool_osize = ConstantInt::get(Type::getInt32Ty(F.getContext()), osize);
#ifdef JL_INLINE_POOL_ALLOC_SUPPORTED
            static const bool inline_alloc = envFlag("JULIA_INLINE_POOL_ALLOC", true);
            static const bool inline_safepoint = envFlag("JULIA_INLINE_POOL_ALLOC_SAFEPOINT", true);
            static const bool inline_newpages = envFlag("JULIA_INLINE_POOL_ALLOC_NEWPAGES", true);
            static const bool inline_cold = envFlag("JULIA_INLINE_POOL_ALLOC_COLD", false);
            // Sites in a cancellation reset region inline the fast path too (see
            // `emitInlinePoolAlloc`); their slow path keeps the reset-safe entry point.
            if (inline_alloc && (inline_cold || !isColdAllocSite(target))) {
                Function *slowFunc = resetSafe ? smallAllocResetSafeFunc : smallAllocFunc;
                CallInst *slowCall = CallInst::Create(slowFunc, { ptls, pool_offs, pool_osize, type });
                slowCall->setAttributes(slowFunc->getAttributes());
                unsigned align = std::max((unsigned)target->getRetAlign().valueOrOne().value(), (unsigned)sizeof(void*));
                slowCall->addRetAttr(Attribute::getWithAlignment(F.getContext(), Align(align)));
                if (sz > 0)
                    slowCall->addDereferenceableRetAttr(sz);
                slowCall->setDebugLoc(target->getDebugLoc());
                Value *res = emitInlinePoolAlloc(builder, T_size, target, ptls, offset, osize,
                                                 inline_safepoint, inline_newpages,
                                                 resetSafe ? type : nullptr, slowCall);
                res->takeName(target);
                return res;
            }
#endif
            newI = builder.CreateCall(resetSafe ? smallAllocResetSafeFunc : smallAllocFunc,
                                      { ptls, pool_offs, pool_osize, type });
            if (sz > 0)
                derefBytes = sz;
        }
    } else {
        auto size = builder.CreateZExtOrTrunc(target->getArgOperand(1), T_size);
        // allocTypedFunc does not include the type tag in the allocation size!
        newI = builder.CreateCall(resetSafe ? allocTypedResetSafeFunc : allocTypedFunc,
                                  { ptls, size, type });
        derefBytes = sizeof(void*);
    }
    newI->setAttributes(newI->getCalledFunction()->getAttributes());
    unsigned align = std::max((unsigned)target->getRetAlign().valueOrOne().value(), (unsigned)sizeof(void*));
    newI->addRetAttr(Attribute::getWithAlignment(F.getContext(), Align(align)));
    if (derefBytes > 0)
        newI->addDereferenceableRetAttr(derefBytes);
    newI->takeName(target);
    return newI;
}

void FinalLowerGC::lowerWriteBarrier(CallInst *target, Function &F) {
    auto parent = target->getArgOperand(0);
    // A NULL child means a field is being cleared (e.g. memoryrefunset!): no
    // young object is stored, so the generational barrier never needs to
    // remember the parent for it. Skip such children and never load their tag
    // (which would dereference null). If every child is NULL there is nothing
    // to remember, so emit no barrier; the caller erases the call.
    SmallVector<Value*, 8> children;
    for (Value *child : writeBarrierChildren(target)) {
        if (isa<ConstantPointerNull>(child->stripPointerCasts()))
            continue;
        children.push_back(child);
    }
    if (children.empty())
        return;
    IRBuilder<> builder(target);
    builder.SetCurrentDebugLocation(target->getDebugLoc());
    auto parTag = EmitLoadTag(builder, T_size, parent, tbaa_tag);
    auto parBits = builder.CreateAnd(parTag, GC_OLD_MARKED, "parent_bits");
    auto parOldMarked = builder.CreateICmpEQ(parBits, ConstantInt::get(T_size, GC_OLD_MARKED), "parent_old_marked");
    auto mayTrigTerm = SplitBlockAndInsertIfThen(parOldMarked, target, false);
    builder.SetInsertPoint(mayTrigTerm);
    mayTrigTerm->getParent()->setName("may_trigger_wb");
    // At every generational boundary above the youngest, the "child marked"
    // optimization does not apply so we can only check whether the parent
    // is already in the relevant remset or not.
    auto parInImage = builder.CreateAnd(parTag, ConstantInt::get(T_size, GC_IN_IMAGE | GC_IN_IMAGE_REMSET), "parent_in_image");
    auto parIsImage = builder.CreateICmpEQ(parInImage, ConstantInt::get(T_size, GC_IN_IMAGE_NOT_REMSET), "parent_is_image");
    Value *anyChldNotMarked = NULL;
    for (Value *child : children) {
        Value *chldBit = builder.CreateAnd(EmitLoadTag(builder, T_size, child, tbaa_tag), GC_MARKED, "child_bit");
        Value *chldNotMarked = builder.CreateICmpEQ(chldBit, ConstantInt::get(T_size, 0), "child_not_marked");
        anyChldNotMarked = anyChldNotMarked ? builder.CreateOr(anyChldNotMarked, chldNotMarked) : chldNotMarked;
    }
    assert(anyChldNotMarked); // children is non-empty
    auto shouldTrigger = builder.CreateOr(parIsImage, anyChldNotMarked, "should_trigger_wb");
    MDBuilder MDB(parent->getContext());
    SmallVector<uint32_t, 2> Weights{1, 9};
    auto trigTerm = SplitBlockAndInsertIfThen(shouldTrigger, mayTrigTerm, false,
                                                MDB.createBranchWeights(Weights));
    trigTerm->getParent()->setName("trigger_wb");
    builder.SetInsertPoint(trigTerm);
    auto qr = builder.CreateCall(getOrDeclare(jl_intrinsics::queueGCRoot), parent);
    // Propagate CancellationLowering's reset-region annotation to the
    // slow-path call, so lowerQueueGCRoot selects the reset-safe entry.
    if (auto *MD = target->getMetadata("julia.reset_region"))
        qr->setMetadata("julia.reset_region", MD);
}
