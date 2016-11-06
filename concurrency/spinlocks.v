(** * Spinlock well synchronized and spinlock clean*)
Require Import compcert.lib.Axioms.

Require Import concurrency.sepcomp. Import SepComp.
Require Import sepcomp.semantics_lemmas.

Require Import concurrency.pos.

From mathcomp.ssreflect Require Import ssreflect ssrbool ssrnat ssrfun eqtype seq fintype finfun.
Set Implicit Arguments.

(*NOTE: because of redefinition of [val], these imports must appear 
  after Ssreflect eqtype.*)
Require Import compcert.common.AST.     (*for typ*)
Require Import compcert.common.Values. (*for val*)
Require Import compcert.common.Globalenvs.
Require Import compcert.common.Events.
Require Import compcert.common.Memory.
Require Import compcert.lib.Integers.

Require Import Coq.ZArith.ZArith.

Require Import concurrency.threads_lemmas.
Require Import concurrency.permissions.
Require Import concurrency.permjoin_def.
Require Import concurrency.concurrent_machine.
Require Import concurrency.memory_lemmas.
Require Import concurrency.dry_context.
Require Import concurrency.dry_machine_lemmas.
Require Import concurrency.executions.
Require Import Coqlib.
Require Import msl.Coqlib2.

Set Bullet Behavior "None".
Set Bullet Behavior "Strict Subproofs".

Module SpinLocks (SEM: Semantics)
       (SemAxioms: SemanticsAxioms SEM)
       (Machines: MachinesSig with Module SEM := SEM)
       (AsmContext: AsmContext SEM Machines).
  Import Machines DryMachine ThreadPool AsmContext.
  Import event_semantics.
  Import Events.

  Module ThreadPoolWF := ThreadPoolWF SEM Machines.
  Module CoreLanguage := CoreLanguage SEM SemAxioms.
  Module CoreLanguageDry := CoreLanguageDry SEM SemAxioms DryMachine.
  Module StepLemmas := StepLemmas SEM Machines.          
  Module Executions := Executions SEM SemAxioms Machines AsmContext.

  Import Executions CoreLanguage CoreLanguageDry ThreadPoolWF StepLemmas.

  Section Spinlocks.

    Hypothesis EM: ClassicalFacts.excluded_middle.

    (** True if two events access at least one common byte*)
    Definition sameLocation ev1 ev2 :=
      match Events.location ev1, Events.location ev2 with
      | Some (b1, ofs1, size1), Some (b2, ofs2, size2) =>
        b1 = b2 /\ exists ofs, Intv.In ofs (ofs1, (ofs1 + Z.of_nat size1)%Z) /\
                         Intv.In ofs (ofs2, (ofs2 + Z.of_nat size2)%Z)
      | _,_ => False
      end.

    (** Competing Events *)

    (** Actions that may compete*)
    Definition caction (ev : Events.machine_event) :=
      match ev with
      | internal _ (event_semantics.Write _ _ _) => Some Write
      | internal _ (event_semantics.Read _ _ _ _) => Some Read
      | internal _ (event_semantics.Alloc _ _ _) => None
      | internal _ (event_semantics.Free _) => None
      | external _ (release _ _) => Some Release
      | external _ (acquire _ _) => Some Acquire
      | external _ (mklock _) => Some Mklock
      | external _ (freelock _) => Some Freelock
      | external _ (spawn _ _ _) => None
      | external _ (failacq _) => Some Failacq
      end.

    (** Two events compete if they access the same location, from a
    different thread. *)

    (*this definition allows reads and writes to compete with release/acq - wrong*)
    (*Definition competes (ev1 ev2 : Events.machine_event) : Prop :=
      thread_id ev1 <> thread_id ev2 /\
      sameLocation ev1 ev2 /\
      caction ev1 /\ caction ev2 /\
      (caction ev1 = Some Write \/
       caction ev2 = Some Write \/
       caction ev1 = Some Mklock \/
       caction ev2 = Some Mklock \/
       caction ev1 = Some Freelock \/
       caction ev2 = Some Freelock). *)

    (* this definition allows makelock/freelock to compete with
    freelock/makelock, that's probably desired*)
    Definition competes (ev1 ev2 : Events.machine_event) : Prop :=
      thread_id ev1 <> thread_id ev2 /\ (* different threads*)
      sameLocation ev1 ev2 /\ (* same location *)
      caction ev1 /\ (* both are competing type*)
      caction ev2 /\ 
      (is_internal ev1 ->
       is_internal ev2 ->
       (** if they are both internal, at least one of them is a Write*)
       action ev1 = Write \/ action ev2 =  Write) /\
      (is_external ev1 \/ is_external ev2 ->
       (** if one of them is external, then at least one of them is a Mklock or
       freelock*)
       action ev1 = Mklock \/ action ev1 = Freelock
       \/ action ev2 = Mklock \/ action ev2 = Freelock).
    
    (** Spinlock well synchronized*)
    Definition spinlock_synchronized (tr : SC.event_trace) :=
      forall i j ev1 ev2,
        i < j ->
        List.nth_error tr i = Some ev1 ->
        List.nth_error tr j = Some ev2 ->
        competes ev1 ev2 ->
        (exists u v eu ev,
          i <= u < v /\ v < j /\
          List.nth_error tr u = Some eu /\
          List.nth_error tr v = Some ev /\
          action eu = Release /\ action ev = Acquire /\
          location eu = location ev) \/
        (** we also consider spawn operations to be synchronizing*)
        (exists u eu,
            i < u < j /\
            List.nth_error tr u = Some eu /\
            action eu = Spawn).
    
    (** Spinlock clean*)
    Definition spinlock_clean (tr : FineConc.event_trace) :=
      forall i j evi evj
        (Hij: i < j)
        (Hi: List.nth_error tr i = Some evi)
        (Hj: List.nth_error tr j = Some evj)
        (Hmklock: action evi = Mklock)
        (Hfreelock: forall u evu, i < u < j ->
                             List.nth_error tr u = Some evu ->
                             action evu <> Freelock \/
                             location evu <> location evi)
        (Hlocation: sameLocation evj evi),
        action evj <> Write /\ action evj <> Read.

    (** After a step that generates a [mklock] event at [address] addr, addr
  will be in the [lockRes] and thread i will have lock permission on addr*)
    Lemma Mklock_lockRes:
      forall i U tr tp m tp' m' addr
        (Hstep: FineConc.MachStep
                  the_ge (i :: U, tr, tp) m
                  (U, tr ++ [:: external i (Events.mklock addr)], tp') m'),
        lockRes tp' addr /\
        forall (cnti': containsThread tp' i) ofs,
          Intv.In ofs (addr.2, addr.2 + lksize.LKSIZE)%Z ->
          ((getThreadR cnti').2 !! (addr.1)) ofs = Some Writable.
    Proof.
      intros.
      inv Hstep; simpl in *;
      try (apply app_eq_nil in H4; discriminate).
      apply app_inv_head in H5.
      destruct ev; simpl in *; discriminate.
      apply app_inv_head in H5;
        inv H5.
      (** case it's an external step that generates a mklock event*)
      inv Htstep.
      rewrite gsslockResUpdLock; split; auto.
      intros cnti'.
      rewrite gLockSetRes gssThreadRes.
      rewrite <- Hlock_perm.
      intros.
      erewrite setPermBlock_same by eauto.
      reflexivity.
    Qed.

    (** [True] whenever some resource in [tp] has above [Readable] lock-permission on [laddr]*)
    (* I could not prove the stronger version, where quantification happens inside each case*)
    Definition isLock tp laddr :=
      forall ofs, Intv.In ofs (laddr.2, laddr.2 + lksize.LKSIZE)%Z ->
      (exists i (cnti: containsThread tp i),
          Mem.perm_order'' ((getThreadR cnti).2 !! (laddr.1) ofs) (Some Readable)) \/
      (exists laddr' rmap, lockRes tp laddr' = Some rmap /\
                      Mem.perm_order'' (rmap.2 !! (laddr.1) ofs) (Some Readable)).

    (** If no freelock event is generated by a step, locks are
    preserved*)
    Lemma remLockRes_Freelock:
      forall i U tr tr' tp m tp' m' addr
        (Hlock: lockRes tp addr)
        (HisLock: isLock tp addr)
        (Hstep: FineConc.MachStep
                  the_ge (i :: U, tr, tp) m
                  (U, tr ++ tr', tp') m')
        (Hev: forall u ev, nth_error tr' u = Some ev ->
                      action ev <> Freelock \/
                      location ev <> Some (addr, lksize.LKSIZE_nat)),
        lockRes tp' addr /\
        isLock tp' addr.
    Proof.
      intros.
      inv Hstep; simpl in *;
      try (inversion Htstep;
            subst tp');
      try (rewrite gsoThreadCLPool; auto);
      try (rewrite gsoThreadLPool; auto);
      try subst tp'0; try subst tp''.
      - (** [threadStep] case*)
        split; auto.
        unfold isLock in *.
        inv HschedN.
        intros ofs0 Hintv.
        destruct (HisLock ofs0 Hintv) as [[j [cntj Hperm]] | [laddr' [rmap' [Hres Hperm]]]].
        + left.
          pose proof (cntUpdate (Krun c') (getCurPerm m'0, (getThreadR Htid).2) Htid cntj) as cntj'.
          exists j, cntj'.
          destruct (tid == j) eqn:Hij;
            move/eqP:Hij=>Hij;
                           subst;
                           [rewrite gssThreadRes | erewrite @gsoThreadRes with (cntj := cntj) by eauto];
                           simpl; pf_cleanup; auto.
        + right.
          exists laddr', rmap'.
          rewrite gsoThreadLPool.
          split; eauto.
      - unfold isLock in *.
        inv HschedN.
        split.
        destruct (EqDec_address (b, Int.intval ofs) addr); subst.
        rewrite gssLockRes; auto.
        erewrite gsoLockRes by eauto.
        rewrite gsoThreadLPool; auto.
        intros ofs0 Hintv.
        specialize (Hangel2 (addr.1) ofs0).
        apply permjoin_order in Hangel2.
        destruct Hangel2 as [Hlt1 Hlt2].
        destruct (HisLock ofs0 Hintv) as [[j [cntj Hperm]] | [laddr' [rmap' [Hres Hperm]]]].
        + pose proof (cntUpdate (Kresume c Vundef) newThreadPerm Htid
                                (cntUpdateL (b, Int.intval ofs) (empty_map, empty_map) cntj)) as cntj'.
          destruct (tid == j) eqn:Hij; move/eqP:Hij=>Hij.
          * subst.
            left.
            exists j, cntj'.
            rewrite gLockSetRes gssThreadRes.
            pf_cleanup.        
            now eauto using po_trans.
          * left.
            exists j, cntj'.
            rewrite gLockSetRes.
            erewrite @gsoThreadRes with (cntj := cntj) by eauto.
            now eauto using po_trans.
        + destruct (EqDec_address (b, Int.intval ofs) laddr').
          * subst.
            left.
            pose proof (cntUpdate (Kresume c Vundef) newThreadPerm Htid
                                  (cntUpdateL (b, Int.intval ofs) (empty_map, empty_map) Htid)) as cnti'.
            exists tid, cnti'.
            rewrite gLockSetRes gssThreadRes.
            rewrite HisLock0 in Hres; inv Hres.
            eauto using po_trans.
          * right.
            exists laddr', rmap'.
            erewrite gsoLockRes by eauto.
            rewrite gsoThreadLPool.
            split; now eauto.
      - unfold isLock in *.
        inv HschedN.        split.
        destruct (EqDec_address (b, Int.intval ofs) addr); subst.
        rewrite gssLockRes; auto.
        erewrite gsoLockRes by eauto.
        rewrite gsoThreadLPool; auto.
        intros ofs0 Hintv.
        specialize (Hangel2 (addr.1) ofs0).
        destruct (HisLock ofs0 Hintv) as [[j [cntj Hperm]] | [laddr' [rmap' [Hres Hperm]]]].
        + destruct (tid == j) eqn:Hij; move/eqP:Hij=>Hij.
          * subst.
            pf_cleanup.
            apply permjoin_readable_iff in Hangel2.
            destruct (Hangel2.1 Hperm) as [Hperm' | Hperm'].
            left.
            exists j, cntj.
            rewrite gLockSetRes gssThreadRes.
            now eauto.
            right.
            exists (b, Int.intval ofs), virtueLP.
            rewrite gssLockRes.
            split;
              now eauto.
          * left.
            exists j, cntj.
            rewrite gLockSetRes.
            erewrite @gsoThreadRes with (cntj := cntj) by eauto.
            now eauto.
        + destruct (EqDec_address (b, Int.intval ofs) laddr').
          * subst.
            rewrite HisLock0 in Hres; inv Hres.
            destruct (Hrmap addr.1 ofs0) as [_ Hrmap2].
            rewrite Hrmap2 in Hperm.
            exfalso. simpl in Hperm.
            now assumption.
          * right.
            exists laddr', rmap'.
            erewrite gsoLockRes by eauto.
            rewrite gsoThreadLPool.
            split; now eauto.
      - unfold isLock in *.
        inv HschedN.
        split;
          first by (rewrite gsoAddLPool gsoThreadLPool;
                    assumption).
        intros ofs0 Hintv.
        specialize (Hangel2 (addr.1) ofs0).
        apply permjoin_readable_iff in Hangel2.
        destruct (HisLock ofs0 Hintv) as [[j [cntj Hperm]] | [laddr' [rmap' [Hres Hperm]]]].
        + destruct (tid == j) eqn:Hij; move/eqP:Hij=>Hij.
          * subst.
            pf_cleanup.
            destruct (Hangel2.1 Hperm) as [Hperm' | Hperm'].
            left.
            exists (latestThread tp), (contains_add_latest (updThread cntj (Kresume c Vundef) threadPerm') (Vptr b ofs) arg newThreadPerm).
            erewrite gssAddRes by reflexivity.
            assumption.
            left.
            exists j, (cntAdd (Vptr b ofs) arg newThreadPerm cntj).
            rewrite @gsoAddRes gssThreadRes.
            assumption.
          * left.
            exists j, (cntAdd (Vptr b ofs) arg newThreadPerm cntj).
            rewrite @gsoAddRes.
            erewrite @gsoThreadRes with (cntj := cntj) by eauto.
            now eauto.
        + right.
          exists laddr', rmap'.
          rewrite gsoAddLPool gsoThreadLPool.
          split;
            now auto.
      - (** Makelock case*)
        inv HschedN.
        split.
        destruct (EqDec_address (b, Int.intval ofs) addr); subst.
        rewrite gssLockRes; auto.
        erewrite gsoLockRes by eauto.
        rewrite gsoThreadLPool;
          now auto.
        intros ofs0 Hintv.
        destruct (HisLock ofs0 Hintv) as [[j [cntj Hperm]] | [laddr' [rmap' [Hres Hperm]]]].
        + left. exists j, cntj.
          rewrite gLockSetRes.
          destruct (tid == j) eqn:Hij; move/eqP:Hij=>Hij.
          * subst.
            pf_cleanup.
            rewrite gssThreadRes.
            rewrite <- Hlock_perm.
            destruct (setPermBlock_or (Some Writable) b (Int.intval ofs) (lksize.LKSIZE_nat) (getThreadR cntj).2 addr.1 ofs0)
              as [Heq | Heq];
              rewrite Heq; simpl; auto using perm_order.
          * rewrite gsoThreadRes;
              now auto.
        + assert ((b, Int.intval ofs) <> laddr')
            by (intros Hcontra; subst; congruence).
          right.
          exists laddr', rmap'.
          erewrite gsoLockRes by eauto.
          rewrite gsoThreadLPool.
          split; auto.
      - (** Interesting case: freelock *)
        unfold isLock in *.
        apply app_inv_head in H5; subst.
        specialize (Hev 0 (external tid (freelock (b, Int.intval ofs)))
                        ltac:(reflexivity)).
        simpl in Hev.
        destruct Hev; first by exfalso.
        erewrite gsolockResRemLock
          by (intros Hcontra; subst; auto).
        rewrite gsoThreadLPool.
        split; auto.
        intros ofs0 Hintv.
        destruct (HisLock ofs0 Hintv) as [[j [cntj Hperm]] | [laddr' [rmap' [Hres Hperm]]]].
        + left.
          exists j, cntj.
          rewrite gRemLockSetRes.
          destruct (tid == j) eqn:Hij; move/eqP:Hij=>Hij.
          * subst.
            pf_cleanup.
            rewrite gssThreadRes.
            rewrite <- Hlock_perm.
            assert (Hneq: b <> addr.1 \/ (b = addr.1) /\ ((ofs0 < (Int.intval ofs))%Z \/ (ofs0 >= (Int.intval ofs) + lksize.LKSIZE)%Z)).
            { destruct (Pos.eq_dec b (addr.1)); subst; auto.
              destruct addr as [b' ofs']; simpl;
                right; split; auto.
              simpl in His_lock, Hintv.
              assert (Hofs': (ofs' + lksize.LKSIZE <= Int.intval ofs \/ ofs' >= Int.intval ofs + lksize.LKSIZE)%Z).
              { destruct (zle (ofs' + lksize.LKSIZE)%Z (Int.intval ofs)).
                - left; auto.
                - destruct (zlt ofs' (Int.intval ofs + lksize.LKSIZE)%Z); eauto.
                  destruct (zlt ofs' (Int.intval ofs)).
                  + exfalso.
                    pose proof (lockRes_valid Hinv b' ofs') as Hvalid.
                    destruct (lockRes tp (b', ofs')) eqn:Hlock'; auto.
                    specialize (Hvalid (Int.intval ofs)).
                    erewrite Hvalid in His_lock.
                    congruence.
                    omega.
                  + exfalso.
                    pose proof (lockRes_valid Hinv b' (Int.intval ofs)) as Hvalid.
                    rewrite His_lock in Hvalid.
                    specialize (Hvalid ofs').
                    erewrite Hvalid in Hlock.
                    now eauto.
                    assert (Hneq: Int.intval ofs <> ofs')
                      by (intros Hcontra; subst; apply H; auto).
                    clear - g l g0 Hneq.
                    omega.
              }
              unfold Intv.In in Hintv.
              simpl in Hintv.
              destruct Hofs'; omega.
            }
            destruct Hneq as [? | [? ?]]; subst;
              [rewrite setPermBlock_other_2 | rewrite setPermBlock_other_1];
              auto.
          * rewrite gsoThreadRes;
              now auto.
        + destruct (EqDec_address (b, Int.intval ofs) laddr').
          * subst.
            rewrite Hres in His_lock; inv His_lock.
            exfalso.
            destruct (Hrmap addr.1 ofs0) as [_ Hrmap2].
            rewrite Hrmap2 in Hperm.
            simpl in Hperm.
            now assumption.
          * right.
            exists laddr', rmap'.
            erewrite gsolockResRemLock;
              now auto.
      - split; assumption.
      - subst tp'; auto.
      - subst tp'; auto.
    Qed.
    
    (** If some address is a lock and there is no event of type Freelock at this
  address in some trace tr then the address is still a lock at the resulting
  state *)
    Lemma remLockRes_Freelock_execution:
      forall U U' tr tr' tp m tp' m' addr
        (Hlock: lockRes tp addr)
        (HisLock: isLock tp addr)
        (Hstep: multi_fstep (U, tr, tp) m
                               (U', tr ++ tr', tp') m')
        (Hfreelock: forall (u : nat) (evu : machine_event),
            nth_error tr' u = Some evu ->
            action evu <> Freelock \/
            location evu <> Some (addr, lksize.LKSIZE_nat)),
        lockRes tp' addr /\
        isLock tp' addr.
    Proof.
      induction U; intros.
      - inversion Hstep.
        rewrite <- app_nil_r in H3 at 1.
        apply app_inv_head in H3; subst.
        split; assumption.
      - inversion Hstep.
        + rewrite <- app_nil_r in H3 at 1.
          apply app_inv_head in H3; subst;
          split; assumption.
        + subst.
          apply app_inv_head in H6. subst.
          eapply remLockRes_Freelock in H8; eauto.
          destruct H8 as [Hres0 HisLock0].
          specialize (IHU U' (tr ++ tr'0) tr'' tp'0 m'0 tp' m' addr Hres0 HisLock0).
          rewrite <- app_assoc in IHU.
          specialize (IHU H9).
          eapply IHU.
          intros u evu Hnth''.
          erewrite nth_error_app with (ys := tr'0) in Hnth''.
          eauto.
          intros.
          erewrite <- nth_error_app1 with (l' := tr'') in H.
          eauto.
          eapply nth_error_Some.
          intros Hcontra; congruence.
    Qed.

    (**TODO: move to dry_machine_lemmas? make a new file with core lemmas?*)
    (** Permissions of addresses that are valid and not freeable do
    not change by internal steps*)
    Lemma ev_elim_stable:
      forall m m' b ofs es
        (Hvalid: Mem.valid_block m b)
        (Hperm: Mem.perm_order'' (Some Writable)
                                 (permission_at m b ofs Cur))
        (Helim: ev_elim m es m'),
        permission_at m b ofs Cur = permission_at m' b ofs Cur.
    Proof.
      intros.
      generalize dependent m.
      induction es as [|ev es]; intros.
      - inversion Helim; subst; auto.
      - simpl in Helim.
        destruct ev;
          try (destruct Helim as [m'' [Haction Helim']]).
        + pose proof (MemoryLemmas.mem_storebytes_cur _ _ _ _ _ Haction b ofs) as Heq.
          do 2 rewrite getCurPerm_correct in Heq.
          rewrite Heq.
          rewrite Heq in Hperm.
          eapply IHes; eauto.
          eapply Mem.storebytes_valid_block_1; eauto.
        + destruct Helim; eauto.
        + pose proof (MemoryLemmas.permission_at_alloc_1
                        _ _ _ _ _ _ ofs Haction Hvalid Cur) as Heq.
          rewrite Heq. rewrite Heq in Hperm.
          eapply IHes; eauto.
          eapply Mem.valid_block_alloc; eauto.
        + assert (Hlt: ~ Mem.perm m b ofs Cur Freeable).
          { intros Hcontra.
            unfold Mem.perm in Hcontra.
            simpl in Hperm. unfold permission_at in *.
            destruct ((Mem.mem_access m) !! b ofs Cur); inv Hperm;
            simpl in Hcontra; inversion Hcontra.
          }
          pose proof (MemoryLemmas.permission_at_free_list_1 _ _ _ _ _
                                                             Haction Hlt Cur) as Heq.
          rewrite Heq. rewrite Heq in Hperm.
          eapply IHes; eauto.
          pose proof (freelist_forward _ _ _ Haction) as Hfwd.
          destruct (Hfwd _ Hvalid); auto.
    Qed.

    (** Spinlock clean for a single step*)
    Lemma fstep_clean:
      forall U U' tp m addr tr pre ev post tp' m' tidi
        (Hlock: lockRes tp addr)
        (HisLock: isLock tp addr)
        (Hlocation: sameLocation ev (external tidi (mklock addr)))
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m
                                  (U', tr ++ pre ++ [:: ev] ++ post, tp') m'),
        action ev <> Write /\ action ev <> Read.
    Proof.
      intros.
      inversion Hstep; simpl in *;
      try match goal with
          | [H: ?X = app ?X ?Y |- _] =>
            rewrite <- app_nil_r in H at 1;
              apply app_inv_head in H
          end; subst;
      try match goal with
          | [H: nth_error [::] _ = _ |- _] =>
            rewrite nth_error_nil in H;
              discriminate
          end;
      try match goal with
          | [H: [::] = ?X ++ (_ :: _) |- _] =>
            destruct X; simpl in H; congruence
          end.
      { (** Case of internal step *)
        (*NOTE: Should spinlock clean also mention free and alloc?*)
        inversion Htstep; subst.
        apply app_inv_head in H5.
        apply ev_step_elim in Hcorestep.
        destruct Hcorestep as [Helim _].
        apply list_append_map_inv in H5.
        destruct H5 as (mpre & mpost & Hpre & Hevpost & Hev0).
        destruct mpost as [|mev mpost];
          simpl in Hevpost; first by discriminate.
        inv Hevpost.
        apply ev_elim_split in Helim.
        destruct Helim as (m2 & ? & Helim_ev).
        unfold sameLocation in Hlocation.
        destruct (location (internal tid mev))
          as [[[b1 ofs1] size1]|] eqn:Haccessed_loc; try by exfalso.
        (** Case location function is defined, i.e. for writes and reads*)
        simpl in Hlocation.
        destruct addr as [bl ofsl].
        destruct Hlocation as [Hb [ofs' [Hintv Hintvl]]].
        (** [ofs'] is the exact offset which both events access*)
        subst.
        (** hence there will be some lock permission that is above [Readable] on
          [address] (bl, ofs') by [isLock] *)
        specialize (HisLock ofs' Hintvl).
        (** and thus all threads will have at most [Nonempty]
          data permission on this [address] by [perm_coh]*)
        assert (Hperm:
                  Mem.perm_order'' (Some Nonempty)
                                   ((getThreadR Htid).1 !! bl ofs')).
        { destruct HisLock as [[j [cntj Hperm]] | [laddr [rmap [Hres Hperm]]]].
          - pose proof ((thread_data_lock_coh Hinv cntj).1 _ Htid bl ofs') as Hcoh.
            clear - Hcoh Hperm.
            simpl in Hperm.
            destruct ((getThreadR Htid).1 !! bl ofs') as [p|]; simpl; auto;
              destruct ((getThreadR cntj).2 !! bl ofs') as [p0|]; simpl in Hperm;
                inversion Hperm; subst;
                  simpl in Hcoh; destruct p;
                    try (by exfalso); eauto using perm_order.
          - pose proof ((locks_data_lock_coh Hinv _ Hres).1 _ Htid bl ofs') as Hcoh.
            clear - Hcoh Hperm.
            simpl in Hperm.
            destruct ((getThreadR Htid).1 !! bl ofs') as [p|]; simpl; auto;
              destruct (rmap.2 !! bl ofs') as [p0|]; simpl in Hperm;
                inversion Hperm; subst;
                  simpl in Hcoh; destruct p;
                    try (by exfalso); eauto using perm_order.
        }

        (** [bl] must be a [Mem.valid_block]*)
        assert (Hvalid: Mem.valid_block m bl)
          by (destruct (lockRes tp (bl, ofsl)) as [rmap|] eqn:Hres; try (by exfalso);
              pose proof (lockRes_blocks Hcmpt (bl, ofsl) Hres);
              eauto).

        (** ev_elim steps cannot change the permission of the lock
          on the memory *)
        rewrite <- restrPermMap_Cur with (Hlt := (Hcmpt tid Htid).1) in Hperm.
        assert (Hperm': Mem.perm_order'' (Some Writable) (permission_at (restrPermMap (Hcmpt tid Htid).1) bl ofs' Cur))
          by (eapply po_trans; eauto; simpl; eauto using perm_order).
        apply (proj2 (restrPermMap_valid (Hcmpt tid Htid).1 bl)) in Hvalid.
        pose proof (ev_elim_stable _ _ _ Hvalid Hperm' H) as Heq.
        simpl in Helim_ev.
        split; intros Haction; simpl in Haction;
        destruct mev; try discriminate;
        simpl in Haccessed_loc; inv Haccessed_loc.
        + (** Case the event is a Write *)
          destruct Helim_ev as [m'' [Hstore Helim']].
          clear - Hstore Heq Hperm Hintv.
          apply Mem.storebytes_range_perm in Hstore.
          specialize (Hstore ofs' Hintv).
          unfold Mem.perm in Hstore.
          unfold permission_at in *.
          destruct (((Mem.mem_access m2) !! bl ofs' Cur)) as [p|]; try destruct p;
          simpl in Hstore; inv Hstore; rewrite Heq in Hperm; simpl in Hperm;
          inv Hperm.
        + (** Case the event is a Read *)
          destruct Helim_ev as [Hload Helim'].
          clear - Hload Heq Hperm Hintv.
          assert (Hlength := Mem.loadbytes_length _ _ _ _ _ Hload).
          apply Mem.loadbytes_range_perm in Hload.
          rewrite Hlength in Hintv.
          unfold Mem.range_perm in Hload.
          rewrite nat_of_Z_max in Hintv.
          destruct (Z.max_dec n 0) as [Hmax | Hmax];
            rewrite Hmax in Hintv. 
          * specialize (Hload ofs' Hintv).
            unfold Mem.perm in Hload.
            unfold permission_at in *.
            rewrite Heq in Hperm.
            destruct (((Mem.mem_access m2) !! bl ofs' Cur)) as [p|]; try destruct p;
            simpl in Hperm; inversion Hperm;
            simpl in Hload; inversion Hload.
          * rewrite Z.add_0_r in Hintv.
            destruct Hintv; simpl in *. omega.
      }
      { (** Case it's an external step*)
        apply app_inv_head in H5.
        destruct pre; simpl in H5;
        inv H5.
        simpl; destruct ev0; split; intro Hcontra; by discriminate.
        destruct pre; simpl in H1; inv H1.
      }
    Qed.
    
    (** FineConc is spinlock clean*)
    Theorem fineConc_clean:
      forall U tr tp m tp' m'
        (Hexec: multi_fstep (U, [::], tp) m ([::], tr, tp') m'),
        spinlock_clean tr.
    Proof.
      unfold spinlock_clean.
      intros.
      replace tr with ([::] ++ tr) in Hexec by reflexivity.
      (** break up the trace in the parts of interest*)
      apply multi_fstep_inv_ext with (i := i) (ev := evi) in Hexec; auto.
      destruct Hexec as (U' & U'' & tp'' & m'' & tr'' & tp''' & m'''
                         & Hexec & Hstep & Hexec' & Hsize).
      destruct evi as [|tidi evi'];
        simpl in Hmklock. destruct m0; discriminate.
      destruct evi'; try discriminate.
      simpl in *.
      rewrite <- app_nil_r with (l := [:: external tidi (mklock a)]) in Hstep;
        rewrite <- app_nil_l with (l := [:: external tidi (mklock a)]) in Hstep; 
        rewrite <- app_assoc in Hstep;
      assert (Hsched: U' = tidi :: U'')
        by (eapply fstep_event_sched in Hstep;
            simpl in Hstep; assumption).
      rewrite Hsched in Hstep.
      (** The thread that executed the [mklock] operation must be in the threadpool*)
      destruct (fstep_ev_contains _ _ _ Hstep) as [cnti cnti'].
      (** since there was a [mklock] event, [a] will be in [lockRes] and the
      thread will have lock-permission on it*)
      apply Mklock_lockRes in Hstep.
      destruct Hstep as [HlockRes''' Hperm'''].
      assert (exists trj, tr = tr'' ++ [:: external tidi (mklock a)] ++ trj)
        by (eapply multi_fstep_trace_monotone in Hexec';
             destruct Hexec' as [? Hexec'];
             rewrite <- app_assoc in Hexec';
             eexists; eauto).
      destruct H as [trj H].
      subst.
      rewrite app_assoc in Hexec'.
      assert (Hj_trj:
                nth_error trj (j - length (tr'' ++ [:: external tidi (mklock a)])) =
                Some evj).
      { rewrite <- nth_error_app2.
        rewrite <- app_assoc. assumption.
        rewrite app_length. simpl. ssromega.
      }
      eapply multi_fstep_inv with (ev := evj) in Hexec'; eauto.
      destruct Hexec' as (Uj' & Uj'' & tpj'' & mj'' & trj'' & pre_j & post_j &
                          tpj''' & mj''' & Hexecj' & Hstepj & Hexecj'' & Hsizej).
      erewrite nth_error_app2 in Hj by ssromega.
      assert (Hlock: lockRes tpj'' a /\ isLock tpj'' a).
      { eapply remLockRes_Freelock_execution with
        (tr := tr'' ++ [:: external tidi (mklock a)]) (tr' := trj''); eauto.
        left.
        exists tidi, cnti'.
        erewrite Hperm''' by eauto.
        simpl; now constructor.
        intros u evu Hnth.
        assert (exists trj''', trj = trj'' ++ pre_j ++ [:: evj] ++ post_j ++ trj''').
        { eapply multi_fstep_trace_monotone in Hexecj''.
          destruct Hexecj'' as [? Hexecj'']. 
          do 3 rewrite <- app_assoc in Hexecj''.
          apply app_inv_head in Hexecj''.
          apply app_inv_head in Hexecj''.
          subst. do 3 rewrite <- app_assoc.
          eexists;
            by eauto.
        }
        destruct H as [trj''' H].
        subst.
        do 2 rewrite app_length in Hsizej.
        simpl in Hsizej.
        eapply (Hfreelock (length (tr'' ++ [:: external tidi (mklock a)]) + u)).
        apply/andP. split.
        rewrite app_length. simpl.
        ssromega.
        rewrite app_length.
        simpl.
        (** u is smaller than length of trj''*)
        assert (Hu: (u < length trj'')%coq_nat)
          by (erewrite <- nth_error_Some; intros Hcontra; congruence).
        rewrite <- ltn_subRL.
        rewrite <- Hsizej. ssromega.
        replace ((tr'' ++
                       [:: external tidi (mklock a)] ++
                       trj'' ++ pre_j ++ [:: evj] ++ post_j ++ trj''')) with
        ((tr'' ++ [:: external tidi (mklock a)]) ++
                                                trj'' ++ pre_j ++ [:: evj] ++
                                                post_j ++ trj''')
          by (rewrite <- app_assoc; reflexivity).
        erewrite <- nth_error_app with (ys := tr'' ++
                                                  [:: external tidi (mklock a)]).
        rewrite nth_error_app1. eauto.
        erewrite <- nth_error_Some. intro Hcontra; congruence.
      }
      destruct Hlock as [HlockResj HisLockj].
      rewrite app_assoc in Hstepj.
      eapply fstep_clean; eauto.
      destruct evi; simpl in *; auto. destruct m0; discriminate.
    Qed.
    
    Definition in_free_list (b : block) ofs xs :=
      exists x, List.In x xs /\
           let '(b', lo, hi) := x in
           b = b' /\
           (lo <= ofs < hi)%Z.

    Fixpoint in_free_list_trace (b : block) ofs es :=
      match es with
      | event_semantics.Free l :: es =>
        in_free_list b ofs l \/ in_free_list_trace b ofs es
      | _ :: es =>
        in_free_list_trace b ofs es
      | [:: ] =>
        False
      end.

    (** If (b, ofs) is in the list of freed addresses then the
          permission was Freeable and became None or it was not allocated*)
    Lemma ev_elim_free_1:
      forall m ev m' b ofs,
        ev_elim m ev m' ->
        in_free_list_trace b ofs ev ->
        (permission_at m b ofs Cur = Some Freeable \/
         ~ Mem.valid_block m b) /\
        permission_at m' b ofs Cur = None /\
        Mem.valid_block m' b /\
        exists e, List.In e ev /\
             match e with
             | event_semantics.Free _ => True
             | _ => False
             end.
    Proof.
    Admitted.

    (** If (b, ofs) is not in the list of freed locations and b
          is a valid block then the permissions remains the same
          (cannot be freed or allocated)*)
    Lemma ev_elim_free_2:
      forall m ev m' b ofs,
        ev_elim m ev m' ->
        ~ in_free_list_trace b ofs ev ->
        Mem.perm_order'' (permission_at m' b ofs Cur) (permission_at m b ofs Cur).
    Proof.
    Admitted.
    

    (** Permission decrease: A thread can decrease its data permissions by:
- Freeing memory.
- Spawning a thread
- A makelock operation, turning data into lock
- Releasing a lock *)
    Lemma data_permission_decrease_step:
      forall U tr tp m U' tp' m' tr' tidn b ofs
        (cnt: containsThread tp tidn)
        (cnt': containsThread tp' tidn)
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hperm: Mem.perm_order'' ((getThreadR cnt).1 !! b ofs) (Some Readable))
        (Hperm': ~ Mem.perm_order'' ((getThreadR cnt').1 !! b ofs) (Some Readable)),
        exists ev,
        (List.In ev tr' /\ action ev = Free /\ deadLocation tp' m' b ofs) \/
        (tr' = [:: ev] /\ action ev = Spawn) \/
        (tr' = [:: ev] /\ action ev = Mklock /\
         thread_id ev = tidn /\
         match location ev with
         | Some (addr, sz) =>
           b = addr.1 /\
           Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
         | None =>
           False
         end) \/
        (tr' = [:: ev] /\ action ev = Release /\ thread_id ev = tidn /\
         exists rmap, match location ev with
                 | Some (laddr, sz) =>
                   sz = lksize.LKSIZE_nat /\
                   lockRes tp' laddr = Some rmap /\
                   Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable)
                 | None => False
                 end).
    Proof.
      intros.
      inv Hstep; simpl in *;
        try apply app_eq_nil in H4;
        try inv Htstep;
        destruct U; inversion HschedN; subst; pf_cleanup;
        try (inv Hhalted);
        try (rewrite gThreadCR in Hperm');
        try  (exfalso; by eauto);
        apply app_inv_head in H5; subst.
      - (** internal step case *)
        destruct (ev_step_elim _ _ _ _ _ _ _ Hcorestep) as [Helim _].
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          (* NOTE: this is decidable*)
          destruct (EM (in_free_list_trace b ofs ev)) as [Hdead | Hlive].
          { (** case this address was freed*)
            eapply ev_elim_free_1 with (m := (restrPermMap (Hcmpt _ cnt).1))
                                         (m' := m'0) in Hdead; eauto.
            destruct Hdead as [Hinit [Hempty [Hvalid' [evf [Hin HFree]]]]].
            destruct Hinit as [Hfreeable | Hinvalid].
            { (** case the block was allocated*)
              destruct evf; try by exfalso.
              exists (internal tidn (event_semantics.Free l)).
              simpl. left.
              rewrite restrPermMap_Cur in Hfreeable.
              split; [|split; auto].
              - apply in_map with (f := fun ev => internal tidn ev) in Hin.
                assumption.
              - constructor.
                + (** [b] is a valid block*)
                  erewrite <- diluteMem_valid.
                  assumption.
                + (** no thread has permission on [(b, ofs)]*)
                  intros.
                  destruct (i == tidn) eqn:Hij; move/eqP:Hij=>Hij; subst.
                  * rewrite gssThreadRes.
                    rewrite getCurPerm_correct.
                    simpl.
                    split; first by assumption.
                    (** To prove that there is no lock permission on that location we use the [invariant]*)
                    pose proof ((thread_data_lock_coh Hinv cnt).1 _ cnt b ofs) as Hcoh.
                    rewrite Hfreeable in Hcoh.
                    simpl in Hcoh.
                    destruct ((getThreadR cnt).2 !! b ofs);
                      [by exfalso | reflexivity].
                  * (** case i is a different thread than the one that stepped*)
                    (** by the invariant*) 
                    assert (cnti' := cntUpdate' cnti).
                    erewrite! gsoThreadRes with (cntj := cnti')
                      by (intro Hcontra; subst; auto).
                    split.
                    pose proof ((no_race_thr Hinv cnti' cnt Hij).1 b ofs) as Hno_race.
                    rewrite Hfreeable in Hno_race.
                    rewrite perm_union_comm in Hno_race.
                    apply no_race_racy in Hno_race.
                    inv Hno_race. reflexivity.
                    now constructor.
                    pose proof ((thread_data_lock_coh Hinv cnti').1 _ cnt b ofs) as Hcoh.
                    rewrite Hfreeable in Hcoh.
                    simpl in Hcoh.
                    destruct ((getThreadR cnti').2 !! b ofs);
                      [by exfalso | reflexivity].
                + (** no lock resource has permission on the location*)
                  intros laddr rmap Hres.
                  rewrite gsoThreadLPool in Hres.
                  split.
                  * pose proof ((no_race Hinv _ cnt Hres).1 b ofs) as Hno_race.
                    rewrite Hfreeable in Hno_race.
                    apply no_race_racy in Hno_race.
                    inversion Hno_race.
                    reflexivity.
                    now constructor.
                  * pose proof (((locks_data_lock_coh Hinv) _ _ Hres).1 _ cnt b ofs) as Hcoh.
                    rewrite Hfreeable in Hcoh.
                    simpl in Hcoh.
                    destruct (rmap.2 !! b ofs);
                      [by exfalso | reflexivity].
            }
            { (** case the block was not allocated*)
              destruct evf; try by exfalso.
              exists (internal tidn (event_semantics.Free l)).
              simpl. left.
              split; [|split; auto].
              - apply in_map with (f := fun ev => internal tidn ev) in Hin.
                assumption.
              - constructor.
                + erewrite <- diluteMem_valid.
                  assumption.
                + intros.
                   destruct (i == tidn) eqn:Hij; move/eqP:Hij=>Hij; subst.
                  * pf_cleanup.
                    rewrite gssThreadRes.
                    rewrite getCurPerm_correct.
                    simpl.
                    split; first by assumption.
                    erewrite restrPermMap_valid in Hinvalid.
                    eapply mem_compatible_invalid_block with (ofs := ofs) in Hinvalid; eauto.
                    erewrite (Hinvalid.1 _ cnt).2.
                    reflexivity.
                  * (** case i is a different thread than the one that stepped*)
                    erewrite restrPermMap_valid in Hinvalid.
                    eapply mem_compatible_invalid_block with (ofs := ofs) in Hinvalid; eauto.
                    rewrite! gsoThreadRes; auto.
                    erewrite (Hinvalid.1 _ cnti).2, (Hinvalid.1 _ cnti).1.
                    split;
                      reflexivity.
                + intros.
                  rewrite gsoThreadLPool in H.
                  erewrite restrPermMap_valid in Hinvalid.
                  eapply mem_compatible_invalid_block with (ofs := ofs) in Hinvalid; eauto.
                  erewrite (Hinvalid.2 _ _ H).2, (Hinvalid.2 _ _ H).1.
                  split;
                    reflexivity.
            }
          }
          { (** case the address was not freed *)
            exfalso.
            clear - Hlive Helim Hperm Hperm' EM.
            eapply ev_elim_free_2 in Hlive; eauto.
            rewrite restrPermMap_Cur in Hlive.
            rewrite gssThreadRes in Hperm', Hperm. simpl in *.
            rewrite getCurPerm_correct in Hperm', Hperm.
            apply Hperm'.
            eapply po_trans;
              now eauto.
          }
        + (** case it was another thread that stepped *)
          exfalso.
          erewrite gsoThreadRes with (cntj := cnt) in Hperm'
            by assumption.
          now eauto.
      - (** lock acquire*)
        (** In this case the permissions of a thread can only increase,
            hence we reach a contradiction by the premise*)
        exfalso.
        clear - Hangel1 Hangel2 HisLock Hperm Hperm'.
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + rewrite gLockSetRes gssThreadRes in Hperm, Hperm'.
          specialize (Hangel1 b ofs).
          apply permjoin_order in Hangel1.
          destruct Hangel1 as [_ Hperm''].
          pf_cleanup.
          apply Hperm'.
          eapply po_trans;
            now eauto.
        + rewrite gLockSetRes gsoThreadRes in Hperm';
            now auto.
      - (** lock release *)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          do 3 right. repeat (split; eauto).
          exists virtueLP; split.
          reflexivity.
          rewrite gssLockRes.
          split. reflexivity.
          rewrite gLockSetRes gssThreadRes in Hperm'.
          specialize (Hangel1 b ofs).
          apply permjoin_readable_iff in Hangel1.
          rewrite! po_oo in Hangel1.
          destruct (Hangel1.1 Hperm);
            first by (simpl in *; by exfalso).
          assumption.
        + exfalso.
          rewrite gLockSetRes gsoThreadRes in Hperm';
            now eauto.
      - (** thread spawn*)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          right.
          left;
            simpl; split;
              now eauto.
        + exfalso.
          rewrite gsoAddRes gsoThreadRes in Hperm';
            now eauto.
      - (** MkLock *)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          do 2 right.
          left.
          do 3 (split; simpl; eauto).
          rewrite gLockSetRes gssThreadRes in Hperm'.
          destruct (Pos.eq_dec b b0).
          * subst.
            split; auto.
            destruct (Intv.In_dec ofs (Int.intval ofs0, Int.intval ofs0 + 4)%Z); auto.
            exfalso.
            rewrite <- Hdata_perm in Hperm'.
            rewrite setPermBlock_other_1 in Hperm'.
            now auto.
            apply Intv.range_notin in n.
            destruct n; eauto.
            simpl. now omega.
          * exfalso.
            rewrite <- Hdata_perm in Hperm'.
            erewrite setPermBlock_other_2 in Hperm' by eauto.
            now auto.
        + exfalso.
          rewrite gLockSetRes gsoThreadRes in Hperm';
            now eauto.
      - exfalso.
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          clear - Hdata_perm Hperm Hperm' Hfreeable Hinv Hpdata.
          rewrite gRemLockSetRes gssThreadRes in Hperm', Hperm.
          destruct (Pos.eq_dec b b0).
          * subst.
            rewrite <- Hdata_perm in Hperm'.
            destruct (Intv.In_dec ofs (Int.intval ofs0, Int.intval ofs0 + lksize.LKSIZE)%Z); auto.
            erewrite setPermBlock_same in Hperm' by eauto.
            apply Hperm'.
            simpl. eapply perm_order_trans;
              now eauto using perm_order.
            rewrite setPermBlock_other_1 in Hperm'.
            now auto. 
            apply Intv.range_notin in n.
            destruct n; eauto.
            unfold lksize.LKSIZE.
            simpl. now omega.
          * exfalso.
            rewrite <- Hdata_perm in Hperm'.
            erewrite setPermBlock_other_2 in Hperm' by eauto.
            now auto.
        + exfalso.
          rewrite gRemLockSetRes gsoThreadRes in Hperm';
            now eauto.
    Qed. 

    (** Lifting [data_permission_decrease_step] to multiple steps using [multi_fstep] *)
    Lemma data_permission_decrease_execution:
      forall U tr tpi mi U' tr' tpj mj
        b ofs tidn
        (cnti: containsThread tpi tidn)
        (cntj: containsThread tpj tidn)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm: Mem.perm_order'' ((getThreadR cnti).1 !! b ofs) (Some Readable))
        (Hperm: ~ Mem.perm_order'' ((getThreadR cntj).1 !! b ofs) (Some Readable)),
      exists tr_pre tru U'' U''' tp_pre m_pre tp_dec m_dec,
        multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
        FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                          (U''', tr ++ tr_pre ++ tru, tp_dec) m_dec /\
        multi_fstep (U''', tr ++ tr_pre ++ tru, tp_dec) m_dec
                       (U', tr ++ tr',tpj) mj /\
        (exists evu,
            (List.In evu tru /\ action evu = Free /\ deadLocation tpj mj b ofs) \/
            (tru = [:: evu] /\ action evu = Spawn) \/
            (tru = [:: evu] /\ action evu = Mklock /\ thread_id evu = tidn /\
             match location evu with
             | Some (addr, sz) =>
               b = addr.1 /\
               Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
             | None => False
             end) \/
            (tru = [:: evu] /\ action evu = Release /\ thread_id evu = tidn /\
             (exists rmap, match location evu with
                      | Some (laddr, sz) =>
                        sz = lksize.LKSIZE_nat /\
                        lockRes tp_dec laddr = Some rmap /\ 
                        Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable)
                         | None => False
                         end))).
    Proof.
      induction U as [|tid' U]; intros.
      - inversion Hexec. apply app_eq_nil in H3; subst.
        pf_cleanup. by congruence.
      - inversion Hexec.
        + apply app_eq_nil in H3; subst.
          pf_cleanup;
            by congruence.
        + apply app_inv_head in H6; subst.
          assert (cnt': containsThread tp' tidn)
            by (eapply fstep_containsThread with (tp := tpi); eauto).
          (** Case the permissions were changed by the inductive step. There
                are two subcases, either they increased and hence we can apply
                the IH again by transitivity or they decreased and
                [data_permission_decrease_step] applies directly*)
            destruct (perm_order''_dec ((getThreadR cnt').1 !! b ofs)
                                       (Some Readable)) as [Hincr | Hdecr].
            
            { (** Case permissions increased*)
              rewrite app_assoc in H9.
              (** And we can apply the IH*)
              destruct (IHU _ _ _ _ _ _ _ _ _ _ _ _ H9 Hincr Hperm0)
                as (tr_pre & tru & U'' & U''' & tp_pre & m_pre & tp_dec
                    & m_dec & Hexec_pre & Hstep & Hexec_post & evu & Hspec).
              destruct Hspec as [[Hin [Haction Hdead]] |
                                 [[Heq Haction] | [[Heq [Haction [Hthreadid Hloc]]]
                                                  | [? [Haction [Hthreadid Hstable]]]]]].
              + (** case the drop was by a [Free] event*)
                exists (tr'0 ++ tr_pre), tru, U'', U''', tp_pre, m_pre, tp_dec, m_dec.
                split.
                econstructor 2; eauto.
                rewrite app_assoc.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                exists evu.
                left.
                split;
                  now auto.
              + (** case the drop was by a [Spawn] event *)
                exists (tr'0 ++ tr_pre), tru, U'', U''', tp_pre, m_pre, tp_dec, m_dec.
                split.
                econstructor 2; eauto.
                rewrite app_assoc.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                exists evu.
                right. left.
                split;
                  now auto.
              + (** case the drop was by a [Mklock] event *)
                exists (tr'0 ++ tr_pre), tru, U'', U''', tp_pre, m_pre, tp_dec, m_dec.
                split.
                econstructor 2; eauto.
                rewrite app_assoc.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                exists evu.
                do 2 right. left.
                split;
                  now auto.
              + (** case the drop was by a [Release] event*)
                exists (tr'0 ++ tr_pre), tru, U'', U''', tp_pre, m_pre, tp_dec, m_dec.
                split.
                econstructor 2; eauto.
                rewrite app_assoc.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                split.
                erewrite! app_assoc in *.
                now eauto.
                exists evu.
                do 3 right.
                split. now auto.
                split. now auto.
                split. now auto.
                destruct Hstable as [rmap Hloc].
                destruct (location evu) as [[[bl ofsl] szl]|]; try (by exfalso).
                destruct Hloc as [HlockRes HpermRes].
                exists rmap;
                  now eauto.
            }
            { (** Case permissions decreased by this step. In that case we don't need the IH*)
              clear IHU.
              exists [::], tr'0, (tid' :: U), U, tpi, mi, tp', m'.
              repeat split.
              + rewrite app_nil_r.
                now constructor.
              + rewrite! app_nil_r. assumption.
              + simpl.
                now assumption.
              + destruct (data_permission_decrease_step _ _ _ _ _ H8 Hperm Hdecr)
                  as [ev [[Hin [Haction Hdead]] | [[? Haction]
                                                  | [[? [Haction [Hthread_id Hloc]]]
                                                    | [? [Haction [Hthread_id Hrmap]]]]]]].
                * exists ev.
                  left.
                  split. now auto.
                  split. now auto.
                  rewrite app_assoc in H9.
                  eapply multi_fstep_deadLocation; eauto.
                * subst.
                  exists ev.
                  right. left.
                  split; now auto.
                * subst.
                  exists ev.
                  do 2 right.
                  left.
                  repeat split; now auto.
                * subst.
                  exists ev.
                  do 3 right.
                  repeat split;
                    now auto.
          }
    Qed.

    

    (** Permission increase: A thread can increase its data permissions on a valid block by:
- If it is spawned
- A freelock operation, turning a lock into data.
- Acquiring a lock *)
    Lemma data_permission_increase_step:
      forall U tr tp m U' tp' m' tr' tidn b ofs
        (cnt: containsThread tp tidn)
        (cnt': containsThread tp' tidn)
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hperm': Mem.perm_order'' ((getThreadR cnt').1 !! b ofs) (Some Readable))
        (Hperm: ~ Mem.perm_order'' ((getThreadR cnt).1 !! b ofs) (Some Readable))
        (Hvalid: Mem.valid_block m b),
        exists ev,
        (tr' = [:: ev] /\ action ev = Spawn) \/
        (tr' = [:: ev] /\ action ev = Freelock /\ thread_id ev = tidn /\
         match location ev with
         | Some (addr, sz) =>
           b = addr.1 /\
           Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
         | None =>
           False
         end) \/
        (tr' = [:: ev] /\ action ev = Acquire /\ thread_id ev = tidn /\
          exists rmap, match location ev with
                  | Some (laddr, sz) =>
                    sz = lksize.LKSIZE_nat /\
                   lockRes tp laddr = Some rmap /\
                   Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable)
                 | None => False
                 end).
    Proof.
      intros.
      inv Hstep; simpl in *;
        try apply app_eq_nil in H4;
        try inv Htstep;
        destruct U; inversion HschedN; subst; pf_cleanup;
        try (inv Hhalted);
        try (rewrite gThreadCR in Hperm');
        try  (exfalso; by eauto);
        apply app_inv_head in H5; subst.
      - (** internal step case *)
        destruct (ev_step_elim _ _ _ _ _ _ _ Hcorestep) as [Helim _].
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          exfalso.
          eapply ev_elim_stable with (b := b) (ofs := ofs) in Helim; eauto.
          rewrite restrPermMap_Cur in Helim.
          rewrite Helim in Hperm.
          rewrite gssThreadRes in Hperm'.
          rewrite getCurPerm_correct in Hperm'.
          now auto.
          rewrite restrPermMap_Cur.
          destruct ((getThreadR cnt).1 !! b ofs) as [p|];
            try (destruct p); simpl in Hperm; simpl;
            eauto using perm_order;
            exfalso; now auto using perm_order.
        + (** case it was another thread that stepped *)
          exfalso.
          erewrite gsoThreadRes with (cntj := cnt) in Hperm'
            by assumption.
          now eauto.
      - (** lock acquire*)
        (** In this case the permissions of a thread can only increase*)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          do 2 right. repeat (split; eauto).
          exists pmap; split.
          reflexivity.
          split.
          assumption.
          specialize (Hangel1 b ofs).
          eapply permjoin_readable_iff in Hangel1.
          rewrite gLockSetRes gssThreadRes in Hperm'.
          rewrite! po_oo in Hangel1.
          destruct (Hangel1.1 Hperm');
            [assumption | exfalso; now auto].
        + exfalso.
          rewrite gLockSetRes gsoThreadRes in Hperm';
            now eauto.
      - (** lock release *)
        exfalso.
        clear - Hangel1 Hangel2 HisLock Hperm Hperm'.
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + rewrite gLockSetRes gssThreadRes in Hperm, Hperm'.
          specialize (Hangel1 b ofs). pf_cleanup.
          simpl in Hangel1.
          apply permjoin_readable_iff in Hangel1.
          apply Hperm.
          eapply Hangel1.
          now eauto.
        + rewrite gLockSetRes gsoThreadRes in Hperm';
            now auto.
      - (** thread spawn*)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          left.
          simpl; split;
          now eauto. 
        + exfalso.
          rewrite gsoAddRes gsoThreadRes in Hperm';
            now eauto.
      - (** MkLock *)
        exfalso.
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          rewrite gLockSetRes gssThreadRes in Hperm'.
          destruct (Pos.eq_dec b b0).
          * subst.
            rewrite <- Hdata_perm in Hperm'.
            destruct (Intv.In_dec ofs (Int.intval ofs0, Int.intval ofs0 + lksize.LKSIZE)%Z); auto.
            erewrite setPermBlock_same in Hperm' by eauto.
            simpl in Hperm'.
            now inv Hperm'.
            rewrite setPermBlock_other_1 in Hperm'.
            now auto.
            simpl.
            apply Intv.range_notin in n.
            destruct n; eauto.
            simpl. unfold lksize.LKSIZE. now omega.
          * rewrite <- Hdata_perm in Hperm'.
            erewrite setPermBlock_other_2 in Hperm' by eauto.
            now auto.
        + exfalso.
          rewrite gLockSetRes gsoThreadRes in Hperm';
            now eauto.
      - (** Freelock*)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          right; left.
          do 3 split; simpl; eauto.
          rewrite gRemLockSetRes gssThreadRes in Hperm'.
          destruct (Pos.eq_dec b b0).
          * subst.
            rewrite <- Hdata_perm in Hperm'.
            destruct (Intv.In_dec ofs (Int.intval ofs0, Int.intval ofs0 + lksize.LKSIZE)%Z); auto.
            exfalso.
            erewrite setPermBlock_other_1 in Hperm'.
            now eauto.
            eapply Intv.range_notin in n; eauto.
            unfold lksize.LKSIZE; simpl; now omega.
          * exfalso.
            rewrite <- Hdata_perm in Hperm'.
            erewrite setPermBlock_other_2 in Hperm' by eauto.
            now auto.
        + exfalso.
          rewrite gRemLockSetRes gsoThreadRes in Hperm';
            now eauto.
    Qed.
    
    Lemma data_permission_increase_execution:
      forall U tr tpi mi U' tr' tpj mj
        b ofs tidn
        (cnti: containsThread tpi tidn)
        (cntj: containsThread tpj tidn)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm': Mem.perm_order'' ((getThreadR cntj).1 !! b ofs) (Some Readable))
        (Hperm: ~ Mem.perm_order'' ((getThreadR cnti).1 !! b ofs) (Some Readable))
        (Hvalid: Mem.valid_block mi b),
      exists tr_pre evu U'' U''' tp_pre m_pre tp_inc m_inc,
        multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
        FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                          (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc /\
        multi_fstep (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc
                       (U', tr ++ tr',tpj) mj /\
         ((action evu = Spawn) \/
         (action evu = Freelock /\ thread_id evu = tidn /\
          match location evu with
          | Some (addr, sz) =>
            b = addr.1 /\
            Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
          | None =>
            False
          end) \/
         (action evu = Acquire /\ thread_id evu = tidn /\
          exists rmap, match location evu with
                  | Some (laddr, sz) =>
                    sz = lksize.LKSIZE_nat /\
                    lockRes tp_pre laddr = Some rmap /\
                    Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable)
                  | None => False
                  end)).
    Proof.
      induction U as [|tid' U]; intros.
      - inversion Hexec. apply app_eq_nil in H3; subst.
        pf_cleanup. by congruence.
      - inversion Hexec.
        + apply app_eq_nil in H3; subst.
          pf_cleanup;
            by congruence.
        + apply app_inv_head in H6; subst.
          assert (cnt': containsThread tp' tidn)
            by (eapply fstep_containsThread with (tp := tpi); eauto).
          (** Case the permissions were changed by the inductive step. There are
                two subcases, either they went above readable and we don't need
                the IH or they did not and we apply the IH*)
          destruct (perm_order''_dec ((getThreadR cnt').1 !! b ofs)
                                     (Some Readable)) as [Hincr | Hstable].
          { (** Case permissions increased *)
            destruct (data_permission_increase_step _ _ _ _ H8 Hincr Hperm Hvalid)
              as [ev Hspec].
            assert (tr'0 = [:: ev])
              by (destruct Hspec as [[? _] | [[? _] | [? _]]]; subst; auto);
              subst.
            exists [::], ev, (tid' :: U), U, tpi, mi, tp', m'.
            repeat split.
            + rewrite app_nil_r.
              now constructor.
            + rewrite! app_nil_r.
              simpl.
              assumption.
            + simpl.
              now assumption.
            + destruct Hspec
                as [[Hin Haction] | [[? [Haction [Hthread_id Hloc]]]
                                    | [? [Haction [Hthread_id Hrmap]]]]];
              now eauto.
          }
          { (** Case permissions did not increase*)
            rewrite app_assoc in H9.
            (** And we can apply the IH*)
            destruct (IHU _ _ _ _ _ _ _ _ _ _ _ _ H9 Hperm' Hstable)
              as (tr_pre & evu & U'' & U''' & tp_pre & m_pre & tp_inc
                  & m_inc & Hexec_pre & Hstep & Hexec_post & Hspec); eauto.
            eapply StepType.fstep_valid_block; eauto.
            destruct Hspec as [Haction | [[Haction [Hthread_id Hloc]]
                                               | [Haction [Hthread_id Hrmap]]]].
             + (** case the increase was by a [Spawn] event *)
              exists (tr'0 ++ tr_pre), evu, U'', U''', tp_pre, m_pre, tp_inc, m_inc.
              split.
              econstructor 2; eauto.
              rewrite app_assoc.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              left; now assumption.
            + (** case the drop was by a [Freelock] event *)
              exists (tr'0 ++ tr_pre), evu, U'', U''', tp_pre, m_pre, tp_inc, m_inc.
              split.
              econstructor 2; eauto.
              rewrite app_assoc.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              right. left.
              split;
                now auto.
            + (** case the drop was by a [Acquire] event*)
              exists (tr'0 ++ tr_pre), evu, U'', U''', tp_pre, m_pre, tp_inc, m_inc.
              split.
              econstructor 2; eauto.
              rewrite app_assoc.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              do 2 right.
              now eauto.
          }
    Qed.

        (** Permission increase: A thread can increase its lock permissions on a valid block by:
- If it is spawned
- A freelock operation, turning a lock into data.
- Acquiring a lock *)
    Lemma lock_permission_increase_step:
      forall U tr tp m U' tp' m' tr' tidn b ofs
        (cnt: containsThread tp tidn)
        (cnt': containsThread tp' tidn)
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hperm': Mem.perm_order'' ((getThreadR cnt').2 !! b ofs) (Some Readable))
        (Hperm: ~ Mem.perm_order'' ((getThreadR cnt).2 !! b ofs) (Some Readable))
        (Hvalid: Mem.valid_block m b),
        exists ev,
        (tr' = [:: ev] /\ action ev = Spawn) \/
        (tr' = [:: ev] /\ action ev = Mklock /\ thread_id ev = tidn /\
         match location ev with
         | Some (addr, sz) =>
           b = addr.1 /\
           Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
         | None =>
           False
         end) \/
        (tr' = [:: ev] /\ action ev = Acquire /\ thread_id ev = tidn /\
          exists rmap, match location ev with
                  | Some (laddr, sz) =>
                    sz = lksize.LKSIZE_nat /\
                   lockRes tp laddr = Some rmap /\
                   Mem.perm_order'' (rmap.2 !! b ofs) (Some Readable)
                 | None => False
                 end).
    Proof.
      intros.
      inv Hstep; simpl in *;
        try apply app_eq_nil in H4;
        try inv Htstep;
        destruct U; inversion HschedN; subst; pf_cleanup;
        try (inv Hhalted);
        try (rewrite gThreadCR in Hperm');
        try  (exfalso; by eauto);
        apply app_inv_head in H5; subst.
      - (** internal step case *)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          exfalso.
          rewrite gssThreadRes in Hperm'.
          simpl in Hperm'.
          now auto.
        + (** case it was another thread that stepped *)
          exfalso.
          erewrite gsoThreadRes with (cntj := cnt) in Hperm'
            by assumption.
          now eauto.
      - (** lock acquire*)
        (** In this case the permissions of a thread can only increase*)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          do 2 right. repeat (split; eauto).
          exists pmap; split.
          reflexivity.
          split.
          assumption.
          specialize (Hangel2 b ofs).
          eapply permjoin_readable_iff in Hangel2.
          rewrite gLockSetRes gssThreadRes in Hperm'.
          rewrite! po_oo in Hangel2.
          destruct (Hangel2.1 Hperm');
            [assumption | exfalso; now auto].
        + exfalso.
          rewrite gLockSetRes gsoThreadRes in Hperm';
            now eauto.
      - (** lock release *)
        exfalso.
        clear - Hangel1 Hangel2 HisLock Hperm Hperm'.
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + rewrite gLockSetRes gssThreadRes in Hperm, Hperm'.
          specialize (Hangel2 b ofs). pf_cleanup.
          simpl in Hangel2.
          apply permjoin_readable_iff in Hangel2.
          apply Hperm.
          eapply Hangel2.
          now eauto.
        + rewrite gLockSetRes gsoThreadRes in Hperm';
            now auto.
      - (** thread spawn*)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          left.
          simpl; split;
          now eauto. 
        + exfalso.
          rewrite gsoAddRes gsoThreadRes in Hperm';
            now eauto.
      - (** MkLock *)
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          eexists.
          right.
          left.
          do 3 (split; simpl; eauto).
          rewrite gLockSetRes gssThreadRes in Hperm'.
          destruct (Pos.eq_dec b b0).
          * subst.
            split; auto.
            destruct (Intv.In_dec ofs (Int.intval ofs0, Int.intval ofs0 + 4)%Z); auto.
            exfalso.
            rewrite <- Hlock_perm in Hperm'.
            rewrite setPermBlock_other_1 in Hperm'.
            now auto.
            apply Intv.range_notin in n.
            destruct n; eauto.
            simpl. now omega.
          * exfalso.
            rewrite <- Hlock_perm in Hperm'.
            erewrite setPermBlock_other_2 in Hperm' by eauto.
            now auto.
        + exfalso.
          rewrite gLockSetRes gsoThreadRes in Hperm';
            now eauto.
      - (** Freelock*)
        exfalso.
        destruct (tid == tidn) eqn:Heq; move/eqP:Heq=>Heq; subst.
        + pf_cleanup.
          clear - Hlock_perm Hperm Hperm' Hfreeable Hinv Hpdata.
          rewrite gRemLockSetRes gssThreadRes in Hperm', Hperm.
          destruct (Pos.eq_dec b b0).
          * subst.
            rewrite <- Hlock_perm in Hperm'.
            destruct (Intv.In_dec ofs (Int.intval ofs0, Int.intval ofs0 + lksize.LKSIZE)%Z); auto.
            erewrite setPermBlock_same in Hperm' by eauto.
            simpl in Hperm';
              now auto.
            rewrite setPermBlock_other_1 in Hperm'.
            now auto. 
            apply Intv.range_notin in n.
            destruct n; eauto.
            unfold lksize.LKSIZE.
            simpl. now omega.
          * exfalso.
            rewrite <- Hlock_perm in Hperm'.
            erewrite setPermBlock_other_2 in Hperm' by eauto.
            now auto.
        + exfalso.
          rewrite gRemLockSetRes gsoThreadRes in Hperm';
            now eauto.
    Qed.
    
    Lemma lock_permission_increase_execution:
      forall U tr tpi mi U' tr' tpj mj
        b ofs tidn
        (cnti: containsThread tpi tidn)
        (cntj: containsThread tpj tidn)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm': Mem.perm_order'' ((getThreadR cntj).2 !! b ofs) (Some Readable))
        (Hperm: ~ Mem.perm_order'' ((getThreadR cnti).2 !! b ofs) (Some Readable))
        (Hvalid: Mem.valid_block mi b),
      exists tr_pre evu U'' U''' tp_pre m_pre tp_inc m_inc,
        multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
        FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                          (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc /\
        multi_fstep (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc
                       (U', tr ++ tr',tpj) mj /\
         ((action evu = Spawn) \/
         (action evu = Mklock /\ thread_id evu = tidn /\
          match location evu with
          | Some (addr, sz) =>
            b = addr.1 /\
            Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
          | None =>
            False
          end) \/
         (action evu = Acquire /\ thread_id evu = tidn /\
          exists rmap, match location evu with
                  | Some (laddr, sz) =>
                    sz = lksize.LKSIZE_nat /\
                    lockRes tp_pre laddr = Some rmap /\
                    Mem.perm_order'' (rmap.2 !! b ofs) (Some Readable)
                  | None => False
                  end)).
    Proof.
      induction U as [|tid' U]; intros.
      - inversion Hexec. apply app_eq_nil in H3; subst.
        pf_cleanup. by congruence.
      - inversion Hexec.
        + apply app_eq_nil in H3; subst.
          pf_cleanup;
            by congruence.
        + apply app_inv_head in H6; subst.
          assert (cnt': containsThread tp' tidn)
            by (eapply fstep_containsThread with (tp := tpi); eauto).
          (** Case the permissions were changed by the inductive step. There are
                two subcases, either they went above readable and we don't need
                the IH or they did not and we apply the IH*)
          destruct (perm_order''_dec ((getThreadR cnt').2 !! b ofs)
                                     (Some Readable)) as [Hincr | Hstable].
          { (** Case permissions increased *)
            destruct (lock_permission_increase_step _ _ _ _ H8 Hincr Hperm Hvalid)
              as [ev Hspec].
            assert (tr'0 = [:: ev])
              by (destruct Hspec as [[? _] | [[? _] | [? _]]]; subst; auto);
              subst.
            exists [::], ev, (tid' :: U), U, tpi, mi, tp', m'.
            repeat split.
            + rewrite app_nil_r.
              now constructor.
            + rewrite! app_nil_r.
              simpl.
              assumption.
            + simpl.
              now assumption.
            + destruct Hspec
                as [[Hin Haction] | [[? [Haction [Hthread_id Hloc]]]
                                    | [? [Haction [Hthread_id Hrmap]]]]];
              now eauto.
          }
          { (** Case permissions did not increase*)
            rewrite app_assoc in H9.
            (** And we can apply the IH*)
            destruct (IHU _ _ _ _ _ _ _ _ _ _ _ _ H9 Hperm' Hstable)
              as (tr_pre & evu & U'' & U''' & tp_pre & m_pre & tp_inc
                  & m_inc & Hexec_pre & Hstep & Hexec_post & Hspec); eauto.
            eapply StepType.fstep_valid_block; eauto.
            destruct Hspec as [Haction | [[Haction [Hthread_id Hloc]]
                                               | [Haction [Hthread_id Hrmap]]]].
             + (** case the increase was by a [Spawn] event *)
              exists (tr'0 ++ tr_pre), evu, U'', U''', tp_pre, m_pre, tp_inc, m_inc.
              split.
              econstructor 2; eauto.
              rewrite app_assoc.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              left; now assumption.
            + (** case the drop was by a [Freelock] event *)
              exists (tr'0 ++ tr_pre), evu, U'', U''', tp_pre, m_pre, tp_inc, m_inc.
              split.
              econstructor 2; eauto.
              rewrite app_assoc.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              right. left.
              split;
                now auto.
            + (** case the drop was by a [Acquire] event*)
              exists (tr'0 ++ tr_pre), evu, U'', U''', tp_pre, m_pre, tp_inc, m_inc.
              split.
              econstructor 2; eauto.
              rewrite app_assoc.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              split.
              erewrite! app_assoc in *.
              now eauto.
              do 2 right.
              now eauto.
          }
    Qed.

    Lemma permission_increase_execution:
      forall U tr tpi mi U' tr' tpj mj
        b ofs tidn
        (cnti: containsThread tpi tidn)
        (cntj: containsThread tpj tidn)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm: (Mem.perm_order'' ((getThreadR cntj).1 !! b ofs) (Some Readable) /\
                 ~ Mem.perm_order'' ((getThreadR cnti).1 !! b ofs) (Some Readable)) \/
                (Mem.perm_order'' ((getThreadR cntj).2 !! b ofs) (Some Readable) /\
                 ~ Mem.perm_order'' ((getThreadR cnti).2 !! b ofs) (Some Readable)))
        (Hvalid: Mem.valid_block mi b),
      exists tr_pre evu U'' U''' tp_pre m_pre tp_inc m_inc,
        multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
        FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                          (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc /\
        multi_fstep (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc
                    (U', tr ++ tr',tpj) mj /\
        ((action evu = Spawn) \/
         (action evu = Freelock /\ thread_id evu = tidn /\
          match location evu with
          | Some (addr, sz) =>
            b = addr.1 /\
            Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
          | None =>
            False
          end) \/
         (action evu = Mklock /\ thread_id evu = tidn /\
          match location evu with
          | Some (addr, sz) =>
            b = addr.1 /\
            Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
          | None =>
            False
          end) \/
         (action evu = Acquire /\ thread_id evu = tidn /\
          exists rmap, match location evu with
                  | Some (laddr, sz) =>
                    sz = lksize.LKSIZE_nat /\
                    lockRes tp_pre laddr = Some rmap /\
                    (Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable) \/
                     Mem.perm_order'' (rmap.2 !! b ofs) (Some Readable))
                  | None => False
                  end)).
    Proof.
      intros.
      destruct Hperm as [[Hperm Hperm'] | [Hperm Hperm']];
      [destruct (data_permission_increase_execution _ _ cnti cntj Hexec Hperm Hperm' Hvalid)
        as (? & ? & ? & ? & ? & ? & ? & ? & ? & ? & ? & Hspec)
      | destruct (lock_permission_increase_execution _ _ cnti cntj Hexec Hperm Hperm' Hvalid)
        as (? & ? & ? & ? & ? & ? & ? & ? & ? & ? & ? & Hspec)];
      destruct Hspec as [? | [[? [? ?]] | [? [? [? ?]]]]];
      do 8 eexists; repeat split; eauto 10;
      destruct (location x0) as [[[? ?] ?] |]; try (by exfalso);
      destruct H4 as [? [? ?]];
      do 3 right;
      repeat split; eauto.
    Qed.

    Lemma lockRes_mklock_step:
      forall U tr tp m U' tp' m' tr' laddr rmap
        (Hres: lockRes tp laddr = None)
        (Hres': lockRes tp' laddr = Some rmap)
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m'),
      exists ev,
        tr' = [:: ev] /\ action ev = Mklock /\
        location ev = Some (laddr, lksize.LKSIZE_nat) /\
        lockRes tp' laddr = Some (empty_map, empty_map).
    Proof.
    Admitted.

    Lemma lockRes_mklock_execution:
      forall U tr tpi mi U' tpj mj tr' laddr rmapj
        (Hres: lockRes tpi laddr = None)
        (Hres': lockRes tpj laddr = Some rmapj)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj),
      exists tr_pre evu U'' U''' tp_pre m_pre tp_mk m_mk,
        multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
        FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                          (U''', tr ++ tr_pre ++ [:: evu], tp_mk) m_mk /\
        multi_fstep (U''', tr ++ tr_pre ++ [:: evu], tp_mk) m_mk
                    (U', tr ++ tr',tpj) mj /\
        action evu = Mklock /\
        location evu = Some (laddr, lksize.LKSIZE_nat) /\
        lockRes tp_mk laddr = Some (empty_map, empty_map).
    Proof.
    Admitted.

    Lemma lockRes_freelock_step:
      forall U tr tp m U' tp' m' tr' laddr rmap
        (Hres: lockRes tp laddr = Some rmap)
        (Hres': lockRes tp' laddr = None)
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m'),
      exists ev,
        tr' = [:: ev] /\ action ev = Freelock /\
        location ev = Some (laddr, lksize.LKSIZE_nat) /\
        forall b ofs, rmap.1 !! b ofs = None /\ rmap.2 !! b ofs = None.
    Proof.
    Admitted.

    Lemma lockRes_freelock_execution:
      forall U tr tpi mi U' tpj mj tr' laddr rmapi
        (Hres: lockRes tpi laddr = Some rmapi)
        (Hres': lockRes tpj laddr = None)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj),
      exists tr_pre evu U'' U''' tp_pre m_pre tp_mk m_mk,
        multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
        FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                          (U''', tr ++ tr_pre ++ [:: evu], tp_mk) m_mk /\
        multi_fstep (U''', tr ++ tr_pre ++ [:: evu], tp_mk) m_mk
                    (U', tr ++ tr',tpj) mj /\
        action evu = Freelock /\
        location evu = Some (laddr, lksize.LKSIZE_nat) /\
        lockRes tp_pre laddr = Some (empty_map, empty_map).
    Proof.
    Admitted.
    
    Lemma lockRes_data_permission_decrease_step:
      forall U tr tp m U' tp' m' tr' laddr rmap rmap' b ofs
        (Hres: lockRes tp laddr = Some rmap)
        (Hres': lockRes tp' laddr = Some rmap')
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hperm: Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable))
        (Hperm': ~ Mem.perm_order'' (rmap'.1 !! b ofs) (Some Readable)),
      exists ev,
        tr' = [:: ev] /\ action ev = Acquire /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      intros.
      inv Hstep; simpl in *;
        try apply app_eq_nil in H4;
        try inv Htstep;
        destruct U; inversion HschedN; subst; pf_cleanup;
        try (inv Hhalted);
        try (rewrite gsoThreadCLPool in Hres');
        try (rewrite Hres in Hres'; inv Hres');
        try  (exfalso; by eauto);
        apply app_inv_head in H5; subst.
      - (** internal step case *)
        exfalso.
        rewrite gsoThreadLPool in Hres'.
        rewrite Hres in Hres'; inv Hres';
        now auto.
      - (** lock acquire*)
        (** In this case the permissions of a lock can decrease*)
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          eexists; split; eauto.
        + exfalso.
          erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** lock release *)
        (** In this case the permissions of a lock can only increase; contradiction.*)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HisLock; inv HisLock.
          rewrite (Hrmap b ofs).1 in Hperm.
          simpl in Hperm.
          assumption.
        + erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** thread spawn*)
        rewrite gsoAddLPool gsoThreadLPool in Hres'.
        rewrite Hres' in Hres; inv Hres;
        now eauto.
      - (** MkLock *)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HlockRes.
          discriminate.
        + erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite gsslockResRemLock in Hres'.
          discriminate.
        + erewrite gsolockResRemLock in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
    Qed.
    

    Lemma lockRes_data_permission_decrease_execution:
      forall U tr tpi mi U' tpj mj tr' laddr rmapi rmapj b ofs
        (Hres: lockRes tpi laddr = Some rmapi)
        (Hres': lockRes tpj laddr = Some rmapj)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm: Mem.perm_order'' (rmapi.1 !! b ofs) (Some Readable))
        (Hperm': ~ Mem.perm_order'' (rmapj.1 !! b ofs) (Some Readable)),
      exists v ev,
        nth_error tr' v = Some ev /\ action ev = Acquire /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      induction U as [|tid' U]; intros.
      - inversion Hexec. apply app_eq_nil in H3; subst.
        rewrite Hres in Hres'; inv Hres';
          by congruence.
      - inversion Hexec.
        + apply app_eq_nil in H3; subst.
          rewrite Hres in Hres'; inv Hres';
            by congruence.
        + apply app_inv_head in H6; subst.
          destruct (lockRes tp' laddr) as [rmap'|] eqn:Hres''.
          { (** Case the lock is still there*)
            destruct (perm_order''_dec (rmap'.1 !! b ofs)
                                       (Some Readable)) as [Hstable | Hdecr].
            { (** Case permissions did not decrease*)
              rewrite app_assoc in H9.
              (** And we can apply the IH*)
              destruct (IHU _ _ _ _ _ _ _ _ _ _ _ _ Hres'' Hres' H9 Hstable Hperm')
                as (v & ev & Hnth & Hact & Hloc).
              exists ((length tr'0) + v), ev.
              split.
              rewrite <- nth_error_app; auto.
              now auto.
            }
            { (** Case permissions decreased *)
              destruct (lockRes_data_permission_decrease_step _ _ _ _ Hres Hres'' H8 Hperm Hdecr)
                as (ev & ? & Hact & Hloc); subst.
              exists 0, ev.
              simpl;
                now auto.
            }
          }
          { (** Case the lock is removed *)
            exfalso.
            eapply lockRes_freelock_step in H8; eauto.
            destruct H8 as (? & ? & ? & ? & Hempty).
            specialize (Hempty b ofs).
            rewrite Hempty.1 in Hperm.
            simpl in Hperm.
            assumption.
          } 
    Qed.

    Lemma lockRes_lock_permission_decrease_step:
      forall U tr tp m U' tp' m' tr' laddr rmap rmap' b ofs
        (Hres: lockRes tp laddr = Some rmap)
        (Hres': lockRes tp' laddr = Some rmap')
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hperm: Mem.perm_order'' (rmap.2 !! b ofs) (Some Readable))
        (Hperm': ~ Mem.perm_order'' (rmap'.2 !! b ofs) (Some Readable)),
      exists ev,
        tr' = [:: ev] /\ action ev = Acquire /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      intros.
      inv Hstep; simpl in *;
        try apply app_eq_nil in H4;
        try inv Htstep;
        destruct U; inversion HschedN; subst; pf_cleanup;
        try (inv Hhalted);
        try (rewrite gsoThreadCLPool in Hres');
        try (rewrite Hres in Hres'; inv Hres');
        try  (exfalso; by eauto);
        apply app_inv_head in H5; subst.
      - (** internal step case *)
        exfalso.
        rewrite gsoThreadLPool in Hres'.
        rewrite Hres in Hres'; inv Hres';
        now auto.
      - (** lock acquire*)
        (** In this case the permissions of a lock can decrease*)
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          eexists; split; eauto.
        + exfalso.
          erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** lock release *)
        (** In this case the permissions of a lock can only increase; contradiction.*)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HisLock; inv HisLock.
          rewrite (Hrmap b ofs).2 in Hperm.
          simpl in Hperm.
          assumption.
        + erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** thread spawn*)
        rewrite gsoAddLPool gsoThreadLPool in Hres'.
        rewrite Hres' in Hres; inv Hres;
        now eauto.
      - (** MkLock *)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HlockRes.
          discriminate.
        + erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite gsslockResRemLock in Hres'.
          discriminate.
        + erewrite gsolockResRemLock in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
    Qed.

    Lemma lockRes_lock_permission_decrease_execution:
      forall U tr tpi mi U' tpj mj tr' laddr rmapi rmapj b ofs
        (Hres: lockRes tpi laddr = Some rmapi)
        (Hres': lockRes tpj laddr = Some rmapj)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm: Mem.perm_order'' (rmapi.2 !! b ofs) (Some Readable))
        (Hperm': ~ Mem.perm_order'' (rmapj.2 !! b ofs) (Some Readable)),
      exists v ev,
        nth_error tr' v = Some ev /\ action ev = Acquire /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      induction U as [|tid' U]; intros.
      - inversion Hexec. apply app_eq_nil in H3; subst.
        rewrite Hres in Hres'; inv Hres';
          by congruence.
      - inversion Hexec.
        + apply app_eq_nil in H3; subst.
          rewrite Hres in Hres'; inv Hres';
            by congruence.
        + apply app_inv_head in H6; subst.
          destruct (lockRes tp' laddr) as [rmap'|] eqn:Hres''.
          { (** Case the lock is still there*)
            destruct (perm_order''_dec (rmap'.2 !! b ofs)
                                       (Some Readable)) as [Hstable | Hdecr].
            { (** Case permissions did not decrease*)
              rewrite app_assoc in H9.
              (** And we can apply the IH*)
              destruct (IHU _ _ _ _ _ _ _ _ _ _ _ _ Hres'' Hres' H9 Hstable Hperm')
                as (v & ev & Hnth & Hact & Hloc).
              exists ((length tr'0) + v), ev.
              split.
              rewrite <- nth_error_app; auto.
              now auto.
            }
            { (** Case permissions decreased *)
              destruct (lockRes_lock_permission_decrease_step _ _ _ _ Hres Hres'' H8 Hperm Hdecr)
                as (ev & ? & Hact & Hloc); subst.
              exists 0, ev.
              simpl;
                now auto.
            }
          }
          { (** Case the lock is removed *)
            exfalso.
            eapply lockRes_freelock_step in H8; eauto.
            destruct H8 as (? & ? & ? & ? & Hempty).
            specialize (Hempty b ofs).
            rewrite Hempty.2 in Hperm.
            simpl in Hperm.
            assumption.
          } 
    Qed.
    
    Lemma lockRes_permission_decrease_execution:
      forall U tr tpi mi U' tpj mj tr' laddr rmapi rmapj b ofs
        (Hres: lockRes tpi laddr = Some rmapi)
        (Hres': lockRes tpj laddr = Some rmapj)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm: (Mem.perm_order'' (rmapi.1 !! b ofs) (Some Readable) /\
                 ~ Mem.perm_order'' (rmapj.1 !! b ofs) (Some Readable)) \/
                (Mem.perm_order'' (rmapi.2 !! b ofs) (Some Readable) /\
                 ~ Mem.perm_order'' (rmapj.2 !! b ofs) (Some Readable))),
      exists v ev,
        nth_error tr' v = Some ev /\ action ev = Acquire /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      intros.
      destruct Hperm as [[Hperm Hperm'] | [Hperm Hperm']];
        eauto using lockRes_data_permission_decrease_execution,
        lockRes_lock_permission_decrease_execution.
    Qed.
      
    Lemma lockRes_data_permission_increase_step:
      forall U tr tp m U' tp' m' tr' laddr rmap rmap' b ofs
        (Hres: lockRes tp laddr = Some rmap)
        (Hres': lockRes tp' laddr = Some rmap')
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hperm: ~ Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable))
        (Hperm': Mem.perm_order'' (rmap'.1 !! b ofs) (Some Readable)),
      exists ev,
        tr' = [:: ev] /\ action ev = Release /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      intros.
      inv Hstep; simpl in *;
      try apply app_eq_nil in H4;
      try inv Htstep;
      destruct U; inversion HschedN; subst; pf_cleanup;
      try (inv Hhalted);
      try (rewrite gsoThreadCLPool in Hres');
      try (rewrite Hres in Hres'; inv Hres');
      try  (exfalso; by eauto);
      apply app_inv_head in H5; subst.
      - (** internal step case *)
        exfalso.
        rewrite gsoThreadLPool in Hres'.
        rewrite Hres in Hres'; inv Hres';
        now auto.
      - (** lock acquire*)
        (** In this case the permissions of a lock can only decrease; contradiction*)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HisLock; inv HisLock.
          specialize (Hangel1 b ofs).
          rewrite gssLockRes in Hres'.
          inv Hres'.
          rewrite empty_map_spec in Hperm'.
          simpl in Hperm'.
          assumption.
        + exfalso.
          erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** lock release *)
        (** In this case the permissions of a lock can increase.*)
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HisLock; inv HisLock.
          eexists; split;
          now eauto.
        + exfalso.
          erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** thread spawn*)
        rewrite gsoAddLPool gsoThreadLPool in Hres'.
        rewrite Hres' in Hres; inv Hres;
        now eauto.
      - (** MkLock *)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HlockRes.
          discriminate.
        + erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite gsslockResRemLock in Hres'.
          discriminate.
        + erewrite gsolockResRemLock in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
    Qed.

    Lemma lockRes_lock_permission_increase_step:
      forall U tr tp m U' tp' m' tr' laddr rmap rmap' b ofs
        (Hres: lockRes tp laddr = Some rmap)
        (Hres': lockRes tp' laddr = Some rmap')
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hperm: ~ Mem.perm_order'' (rmap.2 !! b ofs) (Some Readable))
        (Hperm': Mem.perm_order'' (rmap'.2 !! b ofs) (Some Readable)),
      exists ev,
        tr' = [:: ev] /\ action ev = Release /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      intros.
      inv Hstep; simpl in *;
      try apply app_eq_nil in H4;
      try inv Htstep;
      destruct U; inversion HschedN; subst; pf_cleanup;
      try (inv Hhalted);
      try (rewrite gsoThreadCLPool in Hres');
      try (rewrite Hres in Hres'; inv Hres');
      try  (exfalso; by eauto);
      apply app_inv_head in H5; subst.
      - (** internal step case *)
        exfalso.
        rewrite gsoThreadLPool in Hres'.
        rewrite Hres in Hres'; inv Hres';
        now auto.
      - (** lock acquire*)
        (** In this case the permissions of a lock can only decrease; contradiction*)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HisLock; inv HisLock.
          specialize (Hangel2 b ofs).
          rewrite gssLockRes in Hres'.
          inv Hres'.
          rewrite empty_map_spec in Hperm'.
          simpl in Hperm'.
          assumption.
        + exfalso.
          erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** lock release *)
        (** In this case the permissions of a lock can increase.*)
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HisLock; inv HisLock.
          eexists; split;
          now eauto.
        + exfalso.
          erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - (** thread spawn*)
        rewrite gsoAddLPool gsoThreadLPool in Hres'.
        rewrite Hres' in Hres; inv Hres;
        now eauto.
      - (** MkLock *)
        exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite Hres in HlockRes.
          discriminate.
        + erewrite gsoLockRes in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
      - exfalso.
        destruct (EqDec_address laddr (b0, Int.intval ofs0)).
        + inv e.
          rewrite gsslockResRemLock in Hres'.
          discriminate.
        + erewrite gsolockResRemLock in Hres' by eauto.
          rewrite gsoThreadLPool in Hres'.
          rewrite Hres' in Hres; inv Hres;
          now eauto.
    Qed.

    Lemma lockRes_data_permission_increase_execution:
      forall U tr tpi mi U' tpj mj tr' laddr rmapi rmapj b ofs
        (Hres: lockRes tpi laddr = Some rmapi)
        (Hres': lockRes tpj laddr = Some rmapj)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm: ~ Mem.perm_order'' (rmapi.1 !! b ofs) (Some Readable))
        (Hperm': Mem.perm_order'' (rmapj.1 !! b ofs) (Some Readable)),
      exists v ev,
        nth_error tr' v = Some ev /\ action ev = Release /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
      induction U as [|tid' U]; intros.
      - inversion Hexec. apply app_eq_nil in H3; subst.
        rewrite Hres in Hres'; inv Hres';
          by congruence.
      - inversion Hexec.
        + apply app_eq_nil in H3; subst.
          rewrite Hres in Hres'; inv Hres';
            by congruence.
        + apply app_inv_head in H6; subst.
          destruct (lockRes tp' laddr) as [rmap'|] eqn:Hres''.
          { (** Case the lock is still there*)
            destruct (perm_order''_dec (rmap'.2 !! b ofs)
                                       (Some Readable)) as [Hstable | Hdecr].
            { (** Case permissions did not decrease*)
              rewrite app_assoc in H9.
              (** And we can apply the IH*)
              destruct (IHU _ _ _ _ _ _ _ _ _ _ _ _ Hres'' Hres' H9 Hstable Hperm')
                as (v & ev & Hnth & Hact & Hloc).
              exists ((length tr'0) + v), ev.
              split.
              rewrite <- nth_error_app; auto.
              now auto.
            }
            { (** Case permissions decreased *)
              destruct (lockRes_lock_permission_decrease_step _ _ _ _ Hres Hres'' H8 Hperm Hdecr)
                as (ev & ? & Hact & Hloc); subst.
              exists 0, ev.
              simpl;
                now auto.
            }
          }
          { (** Case the lock is removed *)
            exfalso.
            eapply lockRes_freelock_step in H8; eauto.
            destruct H8 as (? & ? & ? & ? & Hempty).
            specialize (Hempty b ofs).
            rewrite Hempty.2 in Hperm.
            simpl in Hperm.
            assumption.
          } 
    Qed.
    
    Lemma lockRes_permission_increase_execution:
      forall U tr tpi mi U' tpj mj tr' laddr rmapi rmapj b ofs
        (Hres: lockRes tpi laddr = Some rmapi)
        (Hres': lockRes tpj laddr = Some rmapj)
        (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
        (Hperm: (~ Mem.perm_order'' (rmapi.1 !! b ofs) (Some Readable) /\
                 Mem.perm_order'' (rmapj.1 !! b ofs) (Some Readable)) \/
                (~ Mem.perm_order'' (rmapi.2 !! b ofs) (Some Readable) /\
                 Mem.perm_order'' (rmapj.2 !! b ofs) (Some Readable))),
      exists v ev,
        nth_error tr' v = Some ev /\ action ev = Release /\
        location ev = Some (laddr, lksize.LKSIZE_nat).
    Proof.
    Admitted.

    Lemma maximal_competing:
      forall i j tr evi evj
        (Hij: i < j)
        (Hi: nth_error tr i = Some evi)
        (Hj: nth_error tr j = Some evj)
        (Hcompetes: competes evi evj),
      exists k evk, i <= k < j /\
               nth_error tr k = Some evk /\
               competes evk evj /\
               (forall k' evk', k < k' < j ->
                           nth_error tr k' = Some evk' ->
                           ~ competes evk' evj).
    Proof.
      intros i j tr.
      generalize dependent j.
      generalize dependent i.
      induction tr; intros.
      - rewrite nth_error_nil in Hi.
        discriminate.              
      - (** Is there any competing with [evj] event in [tr]?*)
        assert (Hcompeting: (exists k' evk',
                                i < k' < j /\
                                nth_error (a :: tr) k' = Some evk' /\
                                competes evk' evj) \/
                            ~ (exists k' evk',
                                  i < k' < j /\
                                  nth_error (a :: tr) k' = Some evk' /\
                                  competes evk' evj))
          by (eapply EM).
        destruct Hcompeting as [[k' [evk' [Horder [Hk' Hcompete']]]] |
                                Hno_race].
        + (** If yes, then use this to instantiate the IH*)
          destruct k'; first by (exfalso; ssromega).
          destruct j; first by (exfalso; ssromega).
          simpl in *.
          destruct (IHtr k' j evk' evj ltac:(ssromega) Hk' Hj Hcompete')
            as (k & evk & Horder' & Hk & Hcompetekj & Hmaximal).
          exists (S k), evk.
          repeat (split; simpl; eauto).
          ssromega.
          intros k'0 evk'0 Horder'0 Hk'0.
          destruct k'0; first by (exfalso; ssromega).
          simpl in Hk'0.
          eapply Hmaximal; eauto.
        + (** Otherwise [evi] is the first event to compete with [evj] and hence maximal*)
          exists i, evi.
          repeat (split; eauto).
          ssromega.
          intros k' evk' Horder' Hk' Hcompetes'.
          (** but by [Hno_race] there is no event at k' [i < k'] s.t. it competes with evj*)
          eapply Hno_race.
          exists k', evk'.
          split; eauto.
    Qed.

    Lemma free_list_cases:
      forall l m m' b ofs
        (Hfree: Mem.free_list m l = Some m'),
        (permission_at m b ofs Cur = Some Freeable /\
         permission_at m' b ofs Cur = None) \/
        (permission_at m b ofs Cur = permission_at m' b ofs Cur).
    Proof.
    Admitted.

    Lemma elim_perm_valid_block:
      forall m T m' b ofs ofs' bytes
        (Hintv: Intv.In ofs' (ofs, (ofs + Z.of_nat (length bytes))%Z))
        (Helim: ev_elim m T m')
        (Hvalid: Mem.valid_block m b),
        (** Either the location was freed*)
        (permission_at m b ofs' Cur = Some Freeable /\ permission_at m' b ofs' Cur = None) \/
        (** or it wasn't and the operation denoted by the event implies the permission*)
        ((List.In (event_semantics.Write b ofs bytes) T ->
          Mem.perm_order'' (permission_at m b ofs' Cur) (Some Writable) /\
          Mem.perm_order'' (permission_at m' b ofs' Cur) (Some Writable)) /\
         (forall n,
             List.In (event_semantics.Read b ofs n bytes) T ->
             Mem.perm_order'' (permission_at m b ofs' Cur) (Some Readable) /\
             Mem.perm_order'' (permission_at m' b ofs' Cur) (Some Readable))).
    Proof.
      intros.
      generalize dependent m'.
      generalize dependent m.
      induction T as [| ev]; intros.
      - inversion Helim; subst.
        right; split; intros; simpl in H; by exfalso.
      - simpl in Helim.
        destruct ev.
        + destruct Helim as [m'' [Hstore Helim']].
          eapply Mem.storebytes_valid_block_1 in Hvalid; eauto.
          destruct (IHT _ Hvalid _ Helim') as [? | [Hwrite Hread]].
          * pose proof (MemoryLemmas.mem_storebytes_cur _ _ _ _ _ Hstore b ofs') as Heq.
            rewrite! getCurPerm_correct in Heq.
            rewrite Heq.
            left; assumption.
          * assert (in_free_list_trace b ofs' T \/ ~ in_free_list_trace b ofs' T) as Hfree
                by (apply EM).
            destruct Hfree as [Hfree | HnotFree].
            { (** If (b, ofs') was freed in the trace T*)
              eapply ev_elim_free_1 in Hfree; eauto.
              destruct Hfree as [[? | ?] [? [? ?]]]; try (by exfalso).
              left.
              pose proof (MemoryLemmas.mem_storebytes_cur _ _ _ _ _ Hstore b ofs') as Heq.
              rewrite! getCurPerm_correct in Heq.
              rewrite Heq. now eauto.
            }
            { (** If [(b,ofs')] was not freed in [T]*)
              right.
              eapply ev_elim_free_2 in HnotFree; eauto.
              pose proof (MemoryLemmas.mem_storebytes_cur _ _ _ _ _ Hstore b ofs') as Heq.
              rewrite! getCurPerm_correct in Heq.
              rewrite <- Heq in HnotFree.
              clear Heq.
              split.
              - intros Hin.
                simpl in Hin.
                destruct Hin as [Heq | Hin].
                + inv Heq.
                  apply Mem.storebytes_range_perm in Hstore.
                  specialize (Hstore _ Hintv).
                  unfold Mem.perm, permission_at in *.
                  rewrite <- po_oo.
                  split;
                    now eauto using po_trans.
                + specialize (Hwrite Hin).
                  pose proof (MemoryLemmas.mem_storebytes_cur _ _ _ _ _ Hstore b ofs') as Heq.
                  rewrite! getCurPerm_correct in Heq.
                  rewrite Heq.
                  destruct Hwrite;
                    split;
                    now assumption.
              - intros n Hin.
                simpl in Hin.
                destruct Hin as [Heq | Hin].
                discriminate.
                specialize (Hread _ Hin).
                pose proof (MemoryLemmas.mem_storebytes_cur _ _ _ _ _ Hstore b ofs') as Heq.
                rewrite! getCurPerm_correct in Heq.
                rewrite Heq.
                destruct Hread; split;
                  now assumption.
            }
        + (** Case the new operation is a read*)
          destruct Helim as [Hload Helim'].
          destruct (IHT _ Hvalid _ Helim') as [? | [Hwrite Hread]].
          * left; assumption.
          * assert (in_free_list_trace b ofs' T \/ ~ in_free_list_trace b ofs' T) as Hfree
                by (apply EM).
            destruct Hfree as [Hfree | HnotFree].
            { (** If (b, ofs') was freed in the trace T*)
              eapply ev_elim_free_1 in Hfree; eauto.
              destruct Hfree as [[? | ?] [? [? ?]]]; try (by exfalso).
              left.
              now eauto.
            }
            { (** If [(b,ofs')] waas not freed in [T]*)
              right.
              eapply ev_elim_free_2 in HnotFree; eauto.
              split.
              - intros Hin.
                simpl in Hin.
                destruct Hin as [Heq | Hin];
                  first by discriminate.
                destruct (Hwrite Hin).
                split;
                  now assumption.
              - intros n0 Hin.
                simpl in Hin.
                destruct Hin as [Heq | Hin].
                + inv Heq.
                  pose proof (Mem.loadbytes_length _ _ _ _ _ Hload) as Hlength.
                  destruct (zle n0 0).
                  * exfalso.
                    eapply Mem.loadbytes_empty with (m := m) (b := b) (ofs := ofs) in l.
                    rewrite Hload in l. inv l.
                    unfold Intv.In in Hintv. simpl in Hintv.
                    rewrite Z.add_0_r in Hintv.
                    ssromega.
                  * rewrite Hlength in Hintv.
                    erewrite nat_of_Z_eq in Hintv by omega.
                    apply Mem.loadbytes_range_perm in Hload.
                    specialize (Hload _ Hintv).
                    unfold Mem.perm, permission_at in *.
                    split;
                      now eauto using po_trans.
                + split; eapply Hread;
                    now eauto.
            }
        + (** Case thew new operation allocated memory*)
          destruct Helim as [m'' [Halloc Helim']].
          pose proof (Mem.valid_block_alloc _ _ _ _ _ Halloc _ Hvalid) as Hvalid'.
          destruct (IHT _ Hvalid' _ Helim') as [Heq | [Hwrite Hread]].
          * erewrite <- MemoryLemmas.permission_at_alloc_1 in Heq by eauto.
            left; eauto.
          * assert (in_free_list_trace b ofs' T \/ ~ in_free_list_trace b ofs' T) as Hfree
                by (apply EM).
            destruct Hfree as [Hfree | HnotFree].
            { (** If (b, ofs') was freed in the trace T*)
              eapply ev_elim_free_1 in Hfree; eauto.
              destruct Hfree as [[? | ?] [? [? ?]]]; try (by exfalso).
              left.
              erewrite MemoryLemmas.permission_at_alloc_1 by eauto.
              now eauto using po_trans.
            }
            { (** If [(b,ofs')] waas not freed in [T]*)
              right.
              eapply ev_elim_free_2 in HnotFree; eauto.
              split; intros; simpl in H;
              destruct H; try (discriminate);
                erewrite MemoryLemmas.permission_at_alloc_1 by eauto;
                [split; eapply Hwrite | split; eapply Hread];
                now eauto.
            }
        + (** Case the new operation freed memory*)
          destruct Helim as [m'' [Hfree Helim']].
          assert (Hvalid': Mem.valid_block m'' b)
            by (unfold Mem.valid_block in *; erewrite nextblock_freelist by eauto; eauto).
          destruct (IHT _ Hvalid' _ Helim') as [Heq | [Hwrite Hread]].
          * assert (Hperm: Mem.perm m'' b ofs' Cur Freeable)
              by (unfold Mem.perm; unfold permission_at in Heq;
                  rewrite Heq.1; simpl; auto using perm_order).
            pose proof (perm_freelist _ _ _ _ _ Cur Freeable Hfree Hperm) as Hperm'.
            unfold Mem.perm in Hperm'.
            destruct Heq.
            left; split; auto.
            unfold permission_at.
            destruct ((Mem.mem_access m) !! b ofs' Cur) as [p|]; simpl in Hperm';
              inv Hperm'; reflexivity.
          * eapply free_list_cases with (b := b) (ofs := ofs') in Hfree.
            destruct Hfree as [[Heq1 Heq2] | Heq].
            left. split; auto.
            erewrite <- ev_elim_stable; eauto.
            rewrite Heq2.
            now apply po_None.
            rewrite Heq.
            right; split; intros; simpl in H;
              destruct H; try (discriminate);
                eauto.
    Qed.

    Lemma elim_perm_invalid_block:
      forall m T m' b ofs ofs' bytes
        (Hintv: Intv.In ofs' (ofs, (ofs + Z.of_nat (length bytes))%Z))
        (Helim: ev_elim m T m')
        (Hvalid: ~ Mem.valid_block m b),
        (** or it wasn't and the operation denoted by the event implies the permission*)
        (List.In (event_semantics.Write b ofs bytes) T ->
         (permission_at m' b ofs' Cur = Some Freeable \/ permission_at m' b ofs' Cur = None)
         /\ Mem.valid_block m' b) /\
         (forall n,
             List.In (event_semantics.Read b ofs n bytes) T ->
             (permission_at m' b ofs' Cur = Some Freeable \/ permission_at m' b ofs' Cur =  None) /\ Mem.valid_block m' b).
    Proof.
    Admitted.

    Lemma fstep_ev_perm:
      forall U tr tp m U' tr_pre tr_post tp' m' ev
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr_pre ++ [:: ev] ++ tr_post , tp') m'),
        (action ev = Write ->
         forall (cnt: containsThread tp (thread_id ev)) (cnt': containsThread tp' (thread_id ev)),
           match location ev with
           | Some (b, ofs, sz) =>
             forall ofs', Intv.In ofs' (ofs, ofs + Z.of_nat sz)%Z ->
                     (Mem.valid_block m b ->
                      Mem.perm_order'' ((getThreadR cnt).1 !! b ofs') (Some Writable)) /\
                     (Mem.perm_order'' ((getThreadR cnt').1 !! b ofs') (Some Writable) \/
                      deadLocation tp' m' b ofs')
           | None => False
           end) /\
        (action ev = Read ->
         forall (cnt: containsThread tp (thread_id ev)) (cnt': containsThread tp' (thread_id ev)),
           match location ev with
           | Some (b, ofs, sz) =>
             forall ofs', Intv.In ofs' (ofs, ofs + Z.of_nat sz)%Z ->
                     (Mem.valid_block m b ->
                      Mem.perm_order'' ((getThreadR cnt).1 !! b ofs') (Some Readable)) /\
                     (Mem.perm_order'' ((getThreadR cnt').1 !! b ofs') (Some Readable) \/
                      deadLocation tp' m' b ofs')
           | None => False
           end).
    Proof.
      intros.
      inversion Hstep; simpl in *;
        try (apply app_eq_nil in H4;
             subst; destruct tr_pre;
             simpl in H4; discriminate).
      - (** case of internal steps*)
        apply app_inv_head in H5; subst.
        (** proof that the [thread_id] of the event and the head of the schedule match*)
        assert (Hin: List.In ev (map [eta internal tid] ev0))
          by (rewrite H5; apply in_app; right; simpl; auto).
        apply in_map_iff in Hin.
        destruct Hin as [mev [? Hin]].
        subst.
        simpl in *.
        inversion Htstep; subst.
        split; intros Haction Hcnt Hcnt';
          destruct mev; try discriminate;
            pf_cleanup.
        + (** Write case*)
          intros ofs' Hintv.
          pose proof (ev_step_elim _ _ _ _ _ _ _ Hcorestep) as Helim.
          destruct Helim as [Helim _].
          (** By case analysis on whether [b] was a valid block or not*)
          destruct (valid_block_dec m b).
          { (** case [b] is a valid block in [m]*)
            eapply elim_perm_valid_block in Helim; eauto.
            destruct Helim as [[Hfreeable Hempty] | [Hwrite Hread]].
            - (** case the block was freed by the internal step. This implies that
            [(b, ofs)] is now a [deadLocation]*)
              split.
              + intros. rewrite restrPermMap_Cur in Hfreeable.
                rewrite Hfreeable. simpl; now constructor.
              + right.
                constructor; eauto.
                eapply ev_step_validblock with (b := b) in Hcorestep.
                now eauto.
                now eauto.
                intros i cnti.
                rewrite restrPermMap_Cur in Hfreeable.
                pose proof (cntUpdate' cnti) as cnti0.
                eapply invariant_freeable_empty_threads with (j := i) (cntj := cnti0) in Hfreeable;
                  eauto.
                destruct Hfreeable.
                destruct (i == tid) eqn:Heq; move/eqP:Heq=>Heq.
                subst. pf_cleanup.
                rewrite! gssThreadRes.
                simpl.
                rewrite getCurPerm_correct.
                split;
                  now auto.
                rewrite! gsoThreadRes;
                  now auto.
                intros.
                rewrite gsoThreadLPool in H.
                rewrite restrPermMap_Cur in Hfreeable.
                apply invariant_freeable_empty_locks with (laddr := l) (rmap := pmap) in Hfreeable;
                  now eauto.
            - (** case the block was not freed*)
              split.
              + intros. 
                rewrite! restrPermMap_Cur in Hwrite.
                eapply Hwrite;
                  now eauto.
              + rewrite gssThreadRes.
                simpl.
                rewrite getCurPerm_correct.
                left; eapply Hwrite;
                  now eauto.
          }
          { (** case [b] is an invalid block in [m]*)
            eapply elim_perm_invalid_block in Helim; eauto.
            split;
              first by (intros; exfalso; eauto).
            destruct Helim as [Hwrite _].
            rewrite gssThreadRes. simpl.
            destruct (Hwrite Hin) as [[Hallocated | Hfreed] Hvalid'].
            - left.
              rewrite getCurPerm_correct.
              rewrite Hallocated.
              simpl; now constructor.
            - right.
              econstructor; eauto.
              + intros.
                pose proof (cntUpdate' cnti) as cnti0.              
                destruct (i == tid) eqn:Heq; move/eqP:Heq=>Heq.
                * subst. pf_cleanup.
                  rewrite gssThreadRes.
                  simpl. rewrite getCurPerm_correct.
                  split; auto.
                  now eapply (mem_compatible_invalid_block _ Hcmpt n).1.
                * rewrite gsoThreadRes; auto.
                  now eapply (mem_compatible_invalid_block _ Hcmpt n).1.
              + intros.
                rewrite gsoThreadLPool in H.
                split;
                  eapply (mem_compatible_invalid_block _ Hcmpt n).2;
                  now eauto.
          }
        + (** Read case*)
          intros ofs' Hintv.
          pose proof (ev_step_elim _ _ _ _ _ _ _ Hcorestep) as Helim.
          destruct Helim as [Helim _].
          (** By case analysis on whether [b] was a valid block or not*)
          destruct (valid_block_dec m b).
          { (** case [b] is a valid block in [m]*)
            eapply elim_perm_valid_block in Helim; eauto.
            destruct Helim as [[Hfreeable Hempty] | [Hwrite Hread]].
            - (** case the block was freed by the internal step. This implies that
            [(b, ofs)] is now a [deadLocation]*)
              split.
              + intros. rewrite restrPermMap_Cur in Hfreeable.
                rewrite Hfreeable. simpl; now constructor.
              + right.
                constructor; eauto.
                eapply ev_step_validblock with (b := b) in Hcorestep.
                now eauto.
                now eauto.
                intros i cnti.
                rewrite restrPermMap_Cur in Hfreeable.
                pose proof (cntUpdate' cnti) as cnti0.
                eapply invariant_freeable_empty_threads with (j := i) (cntj := cnti0) in Hfreeable;
                  eauto.
                destruct Hfreeable.
                destruct (i == tid) eqn:Heq; move/eqP:Heq=>Heq.
                subst. pf_cleanup.
                rewrite! gssThreadRes.
                simpl.
                rewrite getCurPerm_correct.
                split;
                  now auto.
                rewrite! gsoThreadRes;
                  now auto.
                intros.
                rewrite gsoThreadLPool in H.
                rewrite restrPermMap_Cur in Hfreeable.
                apply invariant_freeable_empty_locks with (laddr := l) (rmap := pmap) in Hfreeable;
                  now eauto.
            - (** case the block was not freed*)
              split.
              + intros. 
                rewrite! restrPermMap_Cur in Hread.
                eapply Hread;
                  now eauto.
              + rewrite gssThreadRes.
                simpl.
                rewrite getCurPerm_correct.
                left; eapply Hread;
                  now eauto.
          }
          { (** case [b] is an invalid block in [m]*)
            eapply elim_perm_invalid_block in Helim; eauto.
            split;
              first by (intros; exfalso; eauto).
            destruct Helim as [_ Hread].
            rewrite gssThreadRes. simpl.
            destruct (Hread _ Hin) as [[Hallocated | Hfreed] Hvalid'].
            - left.
              rewrite getCurPerm_correct.
              rewrite Hallocated.
              simpl; now constructor.
            - right.
              econstructor; eauto.
              + intros.
                pose proof (cntUpdate' cnti) as cnti0.              
                destruct (i == tid) eqn:Heq; move/eqP:Heq=>Heq.
                * subst. pf_cleanup.
                  rewrite gssThreadRes.
                  simpl. rewrite getCurPerm_correct.
                  split; auto.
                  now eapply (mem_compatible_invalid_block _ Hcmpt n0).1.
                * rewrite gsoThreadRes; auto.
                  now eapply (mem_compatible_invalid_block _ Hcmpt n0).1.
              + intros.
                rewrite gsoThreadLPool in H.
                split;
                  eapply (mem_compatible_invalid_block _ Hcmpt n0).2;
                  now eauto.
          }
      - (** case of external steps *)
        apply app_inv_head in H5.
        destruct (tr_pre); simpl;
          inv H5.
        simpl; destruct ev0; split; intros;
          discriminate.
        destruct l; now inv H9.
    Qed.

    (** [FineConc.MachStep] preserves [spinlock_synchronized]*)
    Lemma fineConc_step_synchronized:
      forall U0 U U'  tr tp0 m0 tp m tp' m' tr'
        (Hexec: multi_fstep (U0, [::], tp0) m0 (U, tr, tp) m)
        (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m')
        (Hsynchronized: spinlock_synchronized tr),
        spinlock_synchronized (tr ++ tr').
    Proof.
      intros.
      (** Consider two competing events evi and evj*)
      intros i j evi evj Hneq Hi Hj Hcompetes.
      destruct (lt_dec j (length tr)) as [Hj_in_tr | Hj_not_in_tr].
      - (** If [evj] is in [tr] then so is [evi], by [i < j] and the goal is
        trivial by [Hsynchronized]*)
        assert (Hi_in_tr: (i < length tr)%coq_nat) by ssromega.
        eapply nth_error_app1 with (l' := tr') in Hj_in_tr.
        eapply nth_error_app1 with (l' := tr') in Hi_in_tr.
        rewrite Hi_in_tr in Hi.
        rewrite Hj_in_tr in Hj.
        destruct (Hsynchronized i j evi evj Hneq Hi Hj Hcompetes) as
            [[u [v [eu [ev [Horder [Hevu [Hevv [Hactu [Hactv Hloc]]]]]]]]] |
             [u [eu [Horder [Hu Hactu]]]]].
        + left.
          exists u, v, eu, ev.
          repeat (split; eauto using nth_error_app_inv).
        + right.
          exists u, eu.
          repeat (split; eauto using nth_error_app_inv).
      - (** Hence [evj] is in [tr'] *)
        (** By [maximal_competing] there must exist some maximal event [ek] s.t. it competes with [evj]*)
        destruct (maximal_competing _ _ _ Hneq Hi Hj Hcompetes)
          as (k & evk & Horder & Hk & Hcompetes_kj & Hmaximal).
        (** [evk] cannot be in [tr'] because this would imply that it is from
        the same thread as [j] and hence not competing*)
        assert (Hk_not_in_tr': (k < length tr)%coq_nat).
        { destruct (lt_dec k (length tr)); auto.
          erewrite nth_error_app2 in Hk by omega.
          destruct Hcompetes_kj.
          apply nth_error_In in Hk.
          erewrite nth_error_app2 in Hj by omega.
          apply nth_error_In in Hj.
          eapply fstep_event_tid with (ev := evk) (ev' := evj) in Hstep; eauto.
          exfalso; auto.
        }
        erewrite nth_error_app1 in Hk by assumption.

        (** To find the state that corresponds to [evk] we break the execution
          in [multi_fstep] chunks and the [FineConc.Machstep] that produces [evk]*)
        destruct (multi_fstep_inv _ _ Hk Hexec)
          as (Uk & Uk' & tp_k & m_k & tr0 & pre_k & post_k & tp_k'
              & m_k' & Hexeck & Hstepk & Hexec' & Hk_index).
        erewrite! app_nil_l in *.

        (** *** Useful Results*)
        (** tr' will be of the form tr'_pre ++ evj ++ tr'_post*)
        assert (Htr': exists tr'_pre tr'_post, tr' = tr'_pre ++ [:: evj] ++ tr'_post).
        { erewrite nth_error_app2 in Hj by ssromega.
          apply nth_error_split in Hj.
          destruct Hj as (tr'_pre & tr'_post & ? & ?).
          subst.
          exists tr'_pre, tr'_post.
          reflexivity.
        }
        destruct Htr' as (tr'_pre & tr'_post & Heq). subst.

        (** The threads that generated [evk] and [evj] are
          valid threads in the respective thread pools*)
        assert (cntk: containsThread tp_k (thread_id evk))
          by (eapply fstep_ev_contains in Hstepk;
              eapply Hstepk.1).
        assert (cntk': containsThread tp_k' (thread_id evk))
          by (eapply fstep_ev_contains in Hstepk;
              eapply Hstepk.2).
        assert (cntj: containsThread tp (thread_id evj))
          by (eapply fstep_ev_contains in Hstep;
              eapply Hstep.1).
        assert (cntj': containsThread tp' (thread_id evj))
          by (eapply fstep_ev_contains in Hstep;
              eapply Hstep.2).



        Lemma caction_location:
          forall ev,
            caction ev ->
            exists b ofs sz, location ev = Some (b, ofs, sz).
        Proof.
          intros.
          destruct ev as [? ev | ? ev];
            destruct ev; simpl in *; try (by exfalso);
              try (destruct a);
              do 3 eexists; reflexivity.
        Qed.
      
        inversion Hcompetes_kj as (Hthreads_neq & Hsame_loc & Hcactionk & Hcactionj & _ & _).
        (** [location] is defined for [evk] as it is a competing event*)
        assert (Hloc_k: exists bk ofsk szk, location evk = Some (bk, ofsk, szk))
          by (eapply caction_location; eauto).
        (** [location] is defined for [evj] as it is a competing event*)
        assert (Hloc_j: exists bj ofsj szj, location evj = Some (bj, ofsj, szj))
          by (eapply caction_location; eauto).

        destruct Hloc_k as (b & ofsk & szk & Hloc_k).
        destruct Hloc_j as (b' & ofsj & szj & Hloc_j).
        (** Find the competing byte*)
        unfold sameLocation in Hsame_loc.
        rewrite Hloc_k Hloc_j in Hsame_loc.
        destruct Hsame_loc as [? [ofs [Hintvk Hintvj]]]; subst b'.

        pose proof (multi_fstep_trace_monotone Hexec') as Heq.
        subst.
        destruct Heq as [tr'' Heq]; subst.


        (** The states of the machine satisfy the [invariant]*)
        assert (Hinv: invariant tp)
          by (eapply fstep_invariant; eauto).
        assert (Hinvk': invariant tp_k').
        { destruct (multi_fstep_invariant Hexec') as [Hinvk' | [? _]].
          - now eapply Hinvk'.
          - subst.
            eapply fstep_invariant in Hstep.
            now eapply Hstep.
        }
        
        assert (cntk'_j: containsThread tp (thread_id evk))
          by (eapply fstep_ev_contains in Hstepk;
              destruct Hstepk;
              eapply multi_fstep_containsThread; eauto).

        (** [b] is valid if someone has permission on it*)
        assert (Hvalid_mk': forall p, Mem.perm_order'' ((getThreadR cntk').1 !! b ofs) (Some p) \/
                                 Mem.perm_order'' ((getThreadR cntk').2 !! b ofs) (Some p) ->
                                 Mem.valid_block m_k' b).
        { intros.
          assert (Hlt: permMapLt ((getThreadR cntk').1) (getMaxPerm m_k') /\
                  permMapLt ((getThreadR cntk').2) (getMaxPerm m_k')).
          { destruct (multi_fstep_mem_compatible Hexec') as [Hcompk' | Heq].
            - destruct Hcompk'.
              now eapply (compat_th0 _ cntk').
            - destruct Heq as [? [? _]]; subst.
              eapply fstep_mem_compatible in Hstep.
              now eapply Hstep.
          }
          destruct Hlt.
          destruct H;
            eapply perm_order_valid_block;
            now eauto.
        }
         
        assert (Hvalid_m: forall p, Mem.perm_order'' ((getThreadR cntk').1 !! b ofs) (Some p) \/
                               Mem.perm_order'' ((getThreadR cntk').2 !! b ofs) (Some p) ->
                               Mem.valid_block m b).
        { intros.
          eapply multi_fstep_valid_block; eauto.
        }

        (** *** The Proof*)

        (** We proceed by a case analysis on whether [thread_id evj] was in
            the threadpool at index k. If not then there must have been a
            spawn event between u and j and we are done *)
        destruct (containsThread_dec (thread_id evj) tp_k') as [cntj_k' | Hnot_contained].
        { (** Case [thread_id evj] is in the threadpool*)


          Inductive raction ev : Prop :=
          | read: action ev = Read ->
                  raction ev
          | acq: action ev = Acquire ->
                 raction ev
          | rel: action ev = Release ->
                 raction ev
          | facq: action ev = Failacq ->
                  raction ev.

          Inductive waction ev : Prop:=
          | write: action ev = Write ->
                   waction ev
          | mk: action ev = Mklock ->
                waction ev
          | fl: action ev = Freelock ->
                waction ev.

          Lemma compete_cases:
            forall evi evj
              (Hcompetes: competes evi evj),
              (raction evi /\ waction evj) \/
              (waction evi /\ caction evj).
          Proof.
            intros.
            destruct Hcompetes as (? & ? & Hact1 & Hact2 & Hint & Hext).
            unfold caction.
            destruct evi as [? evi | ? evi], evj as [? evj | ? evj];
              destruct evi, evj; auto 10 using raction, waction;
                simpl in *;
                try (by exfalso);
                try (destruct (Hint ltac:(auto 1) ltac:(auto 1)); discriminate);
                try (destruct (Hext ltac:(auto 2)) as [? | [? | [? | ?]]]; discriminate).
          Qed.

          Lemma fstep_ev_perm_2:
            forall U tr tp m U' tr_pre tr_post tp' m' ev
              (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr_pre ++ [:: ev] ++ tr_post , tp') m'),
              (waction ev -> 
               forall (cnt: containsThread tp (thread_id ev)) (cnt': containsThread tp' (thread_id ev)),
                 match location ev with
                 | Some (b, ofs, sz) =>
                   forall ofs', Intv.In ofs' (ofs, ofs + Z.of_nat sz)%Z ->
                           (Mem.valid_block m b ->
                            Mem.perm_order'' ((getThreadR cnt).1 !! b ofs') (Some Writable) \/
                            Mem.perm_order'' ((getThreadR cnt).2 !! b ofs') (Some Writable)) /\
                           ((Mem.perm_order'' ((getThreadR cnt').1 !! b ofs') (Some Writable) \/
                             Mem.perm_order'' ((getThreadR cnt').2 !! b ofs') (Some Writable)) \/
                            deadLocation tp' m' b ofs')
                 | None => False
                 end) /\
              (caction ev ->
               forall (cnt: containsThread tp (thread_id ev)) (cnt': containsThread tp' (thread_id ev)),
                 match location ev with
                 | Some (b, ofs, sz) =>
                   forall ofs', Intv.In ofs' (ofs, ofs + Z.of_nat sz)%Z ->
                           (Mem.valid_block m b ->
                            Mem.perm_order'' ((getThreadR cnt).1 !! b ofs') (Some Readable) \/
                            Mem.perm_order'' ((getThreadR cnt).2 !! b ofs') (Some Readable)) /\
                           ((Mem.perm_order'' ((getThreadR cnt').1 !! b ofs') (Some Readable) \/
                             Mem.perm_order'' ((getThreadR cnt').2 !! b ofs') (Some Readable)) \/
                            deadLocation tp' m' b ofs')
                 | None => False
                 end).
          Admitted.

          Lemma waction_caction:
            forall ev,
              waction ev -> caction ev.
          Proof.
            intros; destruct ev as [? ev | ? ev]; destruct ev;
              inversion H; (auto || discriminate).
          Qed.

          Lemma raction_caction:
            forall ev,
              raction ev -> caction ev.
          Proof.
            intros; destruct ev as [? ev | ? ev]; destruct ev;
              inversion H; (auto || discriminate).
          Qed.

          Lemma raction_waction:
            forall ev,
              raction ev -> ~ waction ev.
          Proof.
            intros.
            intro Hcontra.
            inversion H; inv Hcontra; congruence.
          Qed.

          Lemma waction_raction:
            forall ev,
              waction ev -> ~ raction ev.
          Proof.
            intros.
            intro Hcontra.
            inversion H; inv Hcontra; congruence.
          Qed.

          (** by [compete_cases] there are two main cases:
- evk is of type [Read], [Acquire], [AcquireFail], [Release] and [evj] is of type [Write], [Mklock], [Freelock] or
- evk is of type [Write], [Mklock], [Freelock] and [evj] is of any type that competes*)
          pose proof (compete_cases Hcompetes_kj) as Hcases.

          (** *** Proving that the permissions required for [evk] and [evj]
              are above [Readable] and incompatible*)

          assert (Hpermissions: (Mem.perm_order'' ((getThreadR cntk').1 !! b ofs) (Some Readable) \/
                                 Mem.perm_order'' ((getThreadR cntk').2 !! b ofs) (Some Readable)) /\
                                (Mem.perm_order'' ((getThreadR cntj).1 !! b ofs) (Some Readable) \/
                                 Mem.perm_order'' ((getThreadR cntj).2 !! b ofs) (Some Readable)) /\
                                (waction evk ->
                                 Mem.perm_order'' ((getThreadR cntk').1 !! b ofs) (Some Writable) \/
                                 Mem.perm_order'' ((getThreadR cntk').2 !! b ofs) (Some Writable)) /\
                                (waction evj ->
                                 Mem.perm_order'' ((getThreadR cntj).1 !! b ofs) (Some Writable) \/
                                 Mem.perm_order'' ((getThreadR cntj).2 !! b ofs) (Some Writable))).
          { destruct(fstep_ev_perm_2 _ _ _ Hstepk) as [Hwritek Hreadk].
            destruct(fstep_ev_perm_2 _ _ _ Hstep) as [Hwritej Hreadj].
            rewrite Hloc_j in Hwritej Hreadj.
            rewrite Hloc_k in Hwritek, Hreadk.
            (** First we prove that [(b, ofs)] cannot be a [deadLocation] *)
            assert (Hnotdead: ~ deadLocation tp_k' m_k' b ofs).
            { (** Suppose that it was. [deadLocation] is preserved by
                      [multi_fstep] and hence [evj] would not have sufficient permissions
                      to perform a [caction]*)
              intros Hdead.
              (** [(b,ofs)] is [deadLocation] at [tp], [m]*)
              eapply multi_fstep_deadLocation with (tp' := tp) (m' := m) in Hdead; eauto.
              (** Hence [b] is a valid block in [m]*)
              inversion Hdead.
              (** Moreover permissions of the machine on [(b, ofs)] are None*)
              destruct (Hthreads _ cntj) as [Hperm1 Hperm2].
              (** The permissions of the thread [thread_id evj] must be above
                      [Readable] by the fact that [evj] is a [caction] event,
                      which leads to a contradiction*)
              pose proof ((Hreadj Hcactionj cntj cntj' ofs Hintvj).1 Hvalid) as Hperm.
              rewrite Hperm1 Hperm2 in Hperm.
              simpl in Hperm.
              destruct Hperm;
                now auto.
            }
            destruct Hcases as [[Hractionk Hwactionj] | [Hwactionk Hwractionj]];
              [ destruct (Hreadk (raction_caction Hractionk) cntk cntk' ofs Hintvk) as [_ [Hpermk | Hcontra]]
              | destruct (Hwritek Hwactionk cntk cntk' ofs Hintvk) as [_ [Hpermk | Hcontra]]];
              try (by exfalso); split;
                try (eapply po_trans; eauto;
                     now constructor);
                specialize (Hvalid_m _ Hpermk);
                repeat match goal with
                       | [H: waction evj |- _] =>
                         destruct (Hwritej H cntj cntj' ofs Hintvj) as [Hpermj _];
                           specialize (Hpermj Hvalid_m); clear Hwritej
                       | [H: is_true (isSome (caction evj)) |- _] =>
                         destruct (Hreadj H cntj cntj' ofs Hintvj) as [Hpermj _];
                           specialize (Hpermj Hvalid_m ); clear Hreadj
                       | [H: waction evk |- _] =>
                         destruct (Hwritek H cntk cntk' ofs Hintvk) as [_ [Hpermk | Hcontra]];
                           clear Hwritek
                       | [H: is_true (isSome (caction evk)) |- _] =>
                         destruct (Hreadk H cntk cntk' ofs Hintvk) as [_ [Hpermk | Hcontra]];
                           clear Hreadk
                       | [ |- _ /\ _] =>
                         split
                       | [H: Mem.perm_order'' ?X ?Y |- Mem.perm_order'' ?X ?Y] =>
                         assumption
                       | [ |- Mem.perm_order'' _ _] =>
                         eapply po_trans; eauto; simpl; now constructor
                       | [H: Mem.perm_order'' _ _ \/ Mem.perm_order'' _ _ |- _] =>
                         destruct H
                       | [H: Mem.perm_order'' ?X ?Y  |- Mem.perm_order'' ?X ?Y \/ _] =>
                         left
                       | [H: Mem.perm_order'' ?X ?Y  |- _ \/ Mem.perm_order'' ?X ?Y] =>
                           right
                       | [ |- _ -> _] => intros
                       | [H: waction ?X, H2: raction ?X |- Mem.perm_order'' _ _] =>
                         exfalso; eapply waction_raction
                       | [H: deadLocation _ _ _ _, H2: ~ deadLocation _ _ _ _ |- _ ] =>
                         exfalso; eauto
                       end;
                eauto.
          }
          destruct Hpermissions as (Hperm_k & Hperm_j & Hwritablek & Hwritablej).

          (** By the [invariant] permissions of [thread_id evk] and
          [thread_id evj] will have compatible permissions at [tp] *)
          assert (Hcompatible11_j: perm_union ((getThreadR cntk'_j).1 !! b ofs)
                                              ((getThreadR cntj).1 !! b ofs))
            by (destruct ((no_race_thr Hinv cntk'_j cntj Hthreads_neq).1 b ofs) as [pu Hcompatiblek'j];
                 rewrite Hcompatiblek'j; auto).

          assert (Hcompatible12_j: perm_coh ((getThreadR cntk'_j).1 !! b ofs)
                                            ((getThreadR cntj).2 !! b ofs))
            by (pose proof ((thread_data_lock_coh Hinv cntj).1 _ cntk'_j b ofs);
                 auto).

          assert (Hcompatible21_j: perm_coh ((getThreadR cntj).1 !! b ofs)
                                              ((getThreadR cntk'_j).2 !! b ofs))
            by (pose proof ((thread_data_lock_coh Hinv cntk'_j).1 _ cntj b ofs);
                 auto).

          assert (Hcompatible22_j: perm_union ((getThreadR cntk'_j).2 !! b ofs)
                                              ((getThreadR cntj).2 !! b ofs))
            by (destruct ((no_race_thr Hinv cntk'_j cntj Hthreads_neq).2 b ofs) as [pu Hcompatiblek'j];
                 rewrite Hcompatiblek'j; auto).
          
          (** There are two main cases: 1. evk is a [raction], 2. evk is a [waction]*)
          destruct Hcases as [[Hractionk Hwactionj] | [Hwactionk _]].
          { (** Case [evk] is an [raction] and [evj] is an [waction]*)
            specialize (Hwritablej Hwactionj).
            assert (Hpermk'_j: ~ Mem.perm_order'' ((getThreadR cntk'_j).1 !! b ofs) (Some Readable)
                               /\ ~ Mem.perm_order'' ((getThreadR cntk'_j).2 !! b ofs) (Some Readable)).
            { clear - Hcompatible11_j Hcompatible12_j Hcompatible21_j
                                      Hcompatible22_j Hwritablej Hthreads_neq.
              destruct Hwritablej as [Hwritablej | Hwritablej];
                [destruct ((getThreadR cntj).1 !! b ofs) as [p1 | ] |
                  destruct ((getThreadR cntj).2 !! b ofs) as [p1 | ]]; simpl in Hwritablej;
              inv Hwritablej;
              destruct ((getThreadR cntk'_j).1 !! b ofs);
              destruct ((getThreadR cntk'_j).2 !! b ofs);
              simpl; split; intros Hcontra;
              inv Hcontra; simpl in *;
              now auto.
            }

            Lemma permission_decrease_execution:
              forall U tr tpi mi U' tr' tpj mj
                b ofs tidn
                (cnti: containsThread tpi tidn)
                (cntj: containsThread tpj tidn)
                (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj)
                (Hperm: (Mem.perm_order'' ((getThreadR cnti).1 !! b ofs) (Some Readable) /\
                         ~ Mem.perm_order'' ((getThreadR cntj).1 !! b ofs) (Some Readable)) \/
                        (Mem.perm_order'' ((getThreadR cnti).2 !! b ofs) (Some Readable) /\
                         ~ Mem.perm_order'' ((getThreadR cntj).2 !! b ofs) (Some Readable))),
              exists tr_pre tru U'' U''' tp_pre m_pre tp_dec m_dec,
                multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
                FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                                  (U''', tr ++ tr_pre ++ tru, tp_dec) m_dec /\
                multi_fstep (U''', tr ++ tr_pre ++ tru, tp_dec) m_dec
                            (U', tr ++ tr',tpj) mj /\
                (exists evu,
                    (List.In evu tru /\ action evu = Free /\ deadLocation tpj mj b ofs) \/
                    (tru = [:: evu] /\ action evu = Spawn) \/
                    (tru = [:: evu] /\ action evu = Mklock /\ thread_id evu = tidn /\
                     match location evu with
                     | Some (addr, sz) =>
                       b = addr.1 /\
                       Intv.In ofs (addr.2, addr.2 + (Z.of_nat sz))%Z
                     | None => False
                     end) \/
                    (tru = [:: evu] /\ action evu = Release /\ thread_id evu = tidn /\
                     (exists rmap, match location evu with
                              | Some (laddr, sz) =>
                                sz = lksize.LKSIZE_nat /\
                                lockRes tp_dec laddr = Some rmap /\ 
                                (Mem.perm_order'' (rmap.1 !! b ofs) (Some Readable) \/
                                 Mem.perm_order'' (rmap.2 !! b ofs) (Some Readable))
                              | None => False
                              end))).
            Proof.
            Admitted.

            assert (Hperm_k_drop:
                      (Mem.perm_order'' (((getThreadR cntk')#1) # b ofs)
                                        (Some Readable) /\
                       ~ Mem.perm_order'' (((getThreadR cntk'_j)#1) # b ofs)
                         (Some Readable)) \/
                      (Mem.perm_order'' (((getThreadR cntk')#2) # b ofs)
                                        (Some Readable) /\
                       ~ Mem.perm_order'' (((getThreadR cntk'_j)#2) # b ofs)
                         (Some Readable)))
              by (destruct Hperm_k; [left | right]; split; destruct Hpermk'_j;
                  now auto).
            (** Hence by [permission_decrease_execution] we have four cases
            for how the permissions of [thread_id evk] dropped*)
            destruct (permission_decrease_execution _ b ofs cntk' cntk'_j Hexec' Hperm_k_drop)
              as (tr_pre_u & tru & ? & ? & tp_pre_u & m_pre_u &
                  tp_dec & m_dec & Hexec_pre_u & Hstepu & Hexec_post_u & evu & Hspec_u).
            destruct Hspec_u as [Hfreed | [Hspawned | [Hmklock | Hrelease]]].
              { (** Case permissions dropped by a [Free] event. This leads to a
                  contradiction because it would be a [deadLocation] *) 
                destruct Hfreed as (HIn & HFree & Hdead).
                inversion Hdead.
                specialize (Hthreads _ cntj).
                rewrite Hthreads.1 Hthreads.2 in Hperm_j.
                simpl in Hperm_j;
                  destruct Hperm_j;
                    by exfalso.
            }
            { (** Case permissions were dropped by a spawn event - we are done*)
              destruct Hspawned as (? & Hactionu).
              subst.
              right.
              remember (tr0 ++ pre_k ++ [:: evk] ++ post_k) as tr00.
              apply multi_fstep_trace_monotone in Hexec_post_u.
              destruct Hexec_post_u as [? Heq].
              rewrite <- app_assoc in Heq.
              apply app_inv_head in Heq. subst.
              exists (length ((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_pre_u)%list), evu.
              split. simpl.
              - apply/andP.
                split.
                + rewrite! app_length.
                  clear - Horder. simpl.
                  move/andP:Horder => [Hle ?].
                  rewrite app_length in Hle.
                  now ssromega.
                + clear - Hj_not_in_tr.
                  erewrite! app_length in *.
                  simpl in *.
                  ssromega.
              - split.
                rewrite! app_assoc.
                rewrite <- app_assoc.
                rewrite <- app_assoc.
                rewrite <- addn0.
                rewrite <- nth_error_app.
                reflexivity.
                assumption.
            }
            { (** Case permissions were dropped by a [Mklock] event - this leads to
                  a contradiction by the fact that [evu] will compete with [evj], while
                  [evk] is the maximal competing event *)
              destruct Hmklock as [Htru [Hactionu [Hthreadu Hlocu]]].
              subst.
              exfalso.
              remember (tr0 ++ pre_k ++ [:: evk] ++ post_k) as tr00.
              apply multi_fstep_trace_monotone in Hexec_post_u.
              destruct Hexec_post_u as [? Heq].
              rewrite <- app_assoc in Heq.
              apply app_inv_head in Heq. subst.
              eapply (Hmaximal (length (tr0 ++ pre_k ++ [:: evk] ++ post_k ++ tr_pre_u)%list) evu).
              - rewrite! app_length.
                apply/andP.
                split.
                + simpl. ssromega.
                + clear - Hj_not_in_tr.
                  rewrite! app_length in Hj_not_in_tr.
                  simpl in *.
                  ssromega.
              - rewrite! app_assoc.
                rewrite <- addn0.
                do 2 rewrite <- app_assoc.
                rewrite <- nth_error_app.
                reflexivity.
              - repeat split.
                + intros Hcontra.
                  rewrite Hthreadu in Hcontra.
                  now auto.
                + destruct (location evu) as [[[bu ofsu] szu]|] eqn:Hloc_u;
                    try (by exfalso).
                  unfold sameLocation.
                  rewrite Hloc_u Hloc_j.
                  simpl in Hlocu.
                  destruct Hlocu as [? Hintvu]; subst.
                  split; auto.
                  exists ofs; split; now auto.
                + destruct evu as [? evu | ? evu];
                    destruct evu; try discriminate.
                  simpl. now auto.
                + destruct evu as [? evu | ? evu];
                    destruct evu; try discriminate.
                  simpl. now auto.
                + intros.
                  destruct evu as [? evu | ? evu];
                    destruct evu; try discriminate.
                + intros.
                  left.
                  assumption.
            }
            { (** Case permissions were dropped by a [Release] event.*)
              destruct Hrelease as [? [Hrelease [Hthread_eq Hrmap]]];
                subst.
              destruct Hrmap as [rmap Hspec].
              destruct (location evu) as [[[bu ofsu] szu]|] eqn:Hlocu;
                try (by exfalso).
              destruct Hspec as [? [Hresu Hperm_rmap]].
              subst.
              (** There are two cases: either [(bu,ofsu)] is a lock at [tp] or it is not*)
              destruct (lockRes tp (bu,ofsu)) as [rmap'|] eqn:Hres.
              - (** Case [(bu, ofsu)] is still a lock at [tp]*)
                (** By the [invariant] its permissions must have dropped because
                [thread_id evj] has a Writable permission at that location*)
                assert (Hperm_res: ~ Mem.perm_order'' (rmap'.1 !! b ofs) (Some Readable) /\
                                   ~ Mem.perm_order'' (rmap'.2 !! b ofs) (Some Readable)).
                { clear - Hinv Hres Hwritablej.
                  destruct ((no_race Hinv _ cntj Hres).1 b ofs) as [pu Hcomp].
                  destruct ((no_race Hinv _ cntj Hres).2 b ofs) as [pu2 Hcomp2].
                  pose proof ((thread_data_lock_coh Hinv cntj).2 _ _ Hres b ofs) as Hcoh.
                  pose proof ((locks_data_lock_coh Hinv _ Hres).1 _ cntj b ofs) as Hcoh2.
                  split; intros Hcontra; destruct Hwritablej;
                  repeat match goal with
                         | [H: Mem.perm_order'' ?X _ |- _] =>
                           destruct X; simpl in H; inv H; simpl in *
                         | [H: match ?X with _ => _ end = _ |- _] =>
                           destruct X
                         end; simpl in *;
                  try (discriminate || by exfalso).
                }
                pose proof (multi_fstep_trace_monotone Hexec_post_u) as [tr''0 Heq].
                rewrite! app_assoc_reverse in Heq.
                do 4 apply app_inv_head in Heq; subst.
                rewrite! app_assoc in Hexec_post_u.

                assert (Hperm_res_drop:
                          (Mem.perm_order'' ((rmap#1) # b ofs) (Some Readable) /\
                           ~ Mem.perm_order'' ((rmap'#1) # b ofs) (Some Readable)) \/
                          (Mem.perm_order'' ((rmap#2) # b ofs) (Some Readable) /\
                           ~ Mem.perm_order'' ((rmap'.2) # b ofs) (Some Readable)))
                  by (destruct Hperm_res; destruct Hperm_rmap; [left | right];
                      now auto).
                (** Hence by [lockRes_permission_decrease_execution] there must
                have been some [Acquire] event on that lock*)
                destruct (lockRes_permission_decrease_execution _ _ _ _ Hresu Hres
                                                                Hexec_post_u Hperm_res_drop)
                  as (v & evv & Hev & Hactionv & Hlocv).
                left.
                exists (length ((tr0 ++ pre_k ++ [:: evk] ++ post_k) ++ tr_pre_u)%list),
                (length ((tr0 ++ pre_k ++ [:: evk] ++ post_k) ++ tr_pre_u ++ [:: evu])%list + v),
                evu, evv.
                repeat split; auto.
                + clear - Horder.
                  erewrite! app_assoc.
                  erewrite! app_length in *.
                  now ssromega.
                + clear - Hj_not_in_tr Hev.
                  erewrite! app_assoc in *.
                  erewrite! app_length in *.
                  erewrite <- Nat.le_ngt in Hj_not_in_tr.
                  pose proof ((nth_error_Some tr''0 v).1 ltac:(intros Hcontra; congruence)).
                  simpl in *.
                  now ssromega.
                + rewrite! app_assoc.
                  do 2 rewrite <- app_assoc.
                  rewrite <- addn0.
                  rewrite <- nth_error_app.
                  reflexivity.
                + rewrite! app_assoc.
                  rewrite <- app_assoc.
                  rewrite <- nth_error_app.
                  apply nth_error_app_inv;
                    now eauto.
                + rewrite Hlocv Hlocu.
                  reflexivity.
              - (** Case [(bu, ofsu)] is no longer a lock*)
                pose proof (multi_fstep_trace_monotone Hexec_post_u) as [tr_fl Heq].
                rewrite! app_assoc_reverse in Heq.
                do 4 apply app_inv_head in Heq; subst.
                rewrite! app_assoc in Hexec_post_u.
                destruct (lockRes_freelock_execution _ _ Hresu Hres Hexec_post_u)
                  as (tr_pre_fl & evfl & ? & ? & tp_pre_fl &
                      m_pre_fl & tp_fl & m_fl & Hexec_pre_fl & Hstep_fl &
                      Hexec_post_fl & Haction_fl & Hloc_fl & Hres_fl).
                (** Hence, at some point in the trace, the permissions at [(bu,
                ofsu)] dropped. This can only be done by an [Acquire] step*)
                assert (Hperm_rmap_empty: ~ Mem.perm_order'' ((empty_map, empty_map).1 !! b ofs)
                                           (Some Readable) /\
                                         ~ Mem.perm_order'' ((empty_map, empty_map).2 !! b ofs)
                                           (Some Readable))
                  by (rewrite empty_map_spec; now auto).

                assert (Hperm_rmap_drop:
                          (Mem.perm_order'' ((rmap#1) # b ofs) (Some Readable) /\
                           ~ Mem.perm_order'' ((empty_map, empty_map).1 # b ofs) (Some Readable)) \/
                          (Mem.perm_order'' ((rmap#2) # b ofs) (Some Readable) /\
                           ~ Mem.perm_order'' ((empty_map, empty_map).2 # b ofs) (Some Readable)))
                  by (destruct Hperm_rmap_empty; destruct Hperm_rmap; [left | right];
                      now auto).
                          
                
                destruct (lockRes_permission_decrease_execution _ _ _ _ Hresu Hres_fl
                                                                Hexec_pre_fl Hperm_rmap_drop)
                  as (v & evv & Hv & Haction_v & Hloc_v).
                left.
                pose proof (multi_fstep_trace_monotone Hexec_post_fl) as [tr_fl' Heq].
                rewrite! app_assoc_reverse in Heq.
                do 6 apply app_inv_head in Heq; subst.
                exists (length ((tr0 ++ pre_k ++ [:: evk] ++ post_k) ++ tr_pre_u)%list),
                (length (((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_pre_u) ++ [:: evu])%list + v),
                evu, evv.
                repeat split; auto.
                * clear - Horder.
                  erewrite! app_assoc.
                  erewrite! app_length in *.
                  now ssromega.
                * clear - Hj_not_in_tr Hv.
                  erewrite! app_assoc in *.
                  erewrite! app_length in *.
                  erewrite <- Nat.le_ngt in Hj_not_in_tr.
                  pose proof ((nth_error_Some tr_pre_fl v).1 ltac:(intros Hcontra; congruence)).
                  simpl in *.
                  now ssromega.
                * rewrite! app_assoc.
                  do 4 rewrite <- app_assoc.
                  rewrite <- addn0.
                  rewrite <- nth_error_app.
                  reflexivity.
                * rewrite! app_assoc.
                  do 3 rewrite <- app_assoc.
                  rewrite <- nth_error_app.
                  apply nth_error_app_inv;
                    now eauto.
                * rewrite Hloc_v Hlocu.
                  reflexivity.
            }
          }
          { (** Case [evk] is a [waction] *)
            specialize (Hwritablek Hwactionk).
            (** [thread_id evj] must have permissions that are below [Readable]*)
            assert (Hpermj_k': ~ Mem.perm_order'' ((getThreadR cntj_k').1 !! b ofs) (Some Readable) /\
                               ~ Mem.perm_order'' ((getThreadR cntj_k').2 !! b ofs) (Some Readable)).
              { clear - Hperm_k Hinvk' Hwritablek Hthreads_neq.
                pose proof ((no_race_thr Hinvk' cntk' cntj_k' Hthreads_neq).1 b ofs) as Hcomp.
                assert (Hcompatible12_j: perm_coh ((getThreadR cntk').1 !! b ofs)
                                                  ((getThreadR cntj_k').2 !! b ofs))
                  by (pose proof ((thread_data_lock_coh Hinvk' cntj_k').1 _ cntk' b ofs);
                       auto).

                assert (Hcompatible21_j: perm_coh ((getThreadR cntj_k').1 !! b ofs)
                                                  ((getThreadR cntk').2 !! b ofs))
                  by (pose proof ((thread_data_lock_coh Hinvk' cntk').1 _ cntj_k' b ofs);
                       auto).

                pose proof ((no_race_thr Hinvk' cntk' cntj_k' Hthreads_neq).2 b ofs) as Hcomp2.
                destruct Hwritablek as [Hwritablek | Hwritablek];
                  [destruct ((getThreadR cntk').1 !! b ofs) as [p1 | ] |
                   destruct ((getThreadR cntk').2 !! b ofs) as [p1 | ]]; simpl in Hwritablek;
                  inv Hwritablek;
                  destruct ((getThreadR cntj_k').1 !! b ofs);
                  destruct ((getThreadR cntj_k').2 !! b ofs);
                  simpl; split; intros Hcontra;
                  inv Hcontra; simpl in *;
                  try (destruct Hcomp);
                  try (destruct Hcomp2);
                  try (auto || discriminate).
              }

              assert (Hperm_incr:
                        (Mem.perm_order'' (((getThreadR cntj)#1) # b ofs) (Some Readable) /\
                         ~ Mem.perm_order'' (((getThreadR cntj_k')#1) # b ofs) (Some Readable)) \/
                        (Mem.perm_order'' (((getThreadR cntj)#2) # b ofs) (Some Readable) /\
                         ~ Mem.perm_order'' (((getThreadR cntj_k')#2) # b ofs) (Some Readable)))
              by (destruct Hpermj_k'; destruct Hperm_j; now auto).
              (** By [permission_increase_execution] we have four cases as
              to how the permissions increased*)
              destruct (permission_increase_execution _ ofs cntj_k' cntj Hexec' Hperm_incr)
                as (tr_pre_v & evv & ? & ? & tp_pre_v & m_pre_v &
                    tp_inc & m_inc & Hexec_pre_v & Hstepv & Hexec_post_v & Hspec_v); eauto.
              (** Proof of equality of traces*)
              pose proof (multi_fstep_trace_monotone Hexec_post_v) as Heq_trace.
              destruct Heq_trace as [tr''0 Heq_trace].
              erewrite! app_assoc_reverse in Heq_trace.
              do 4 apply app_inv_head in Heq_trace. subst.
              rewrite! app_assoc.
              destruct Hspec_v as [Hactionv | [[Hactionv [Hthreadv Hloc_v]] |
                                               [Hactionv [Hthreadv Hrmap]]]].
              - (** Case permissions were increased by a [Spawn] event*)
                right.
                exists (length (((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_pre_v)%list)), evv.
                repeat split.
                + clear - Hj_not_in_tr Horder.
                  erewrite! app_assoc in *.
                  erewrite! app_length in *.
                  simpl.
                  apply/andP.
                  split.
                  now ssromega.
                  erewrite <- Nat.le_ngt in Hj_not_in_tr.
                  simpl in *.
                  now ssromega.
                + rewrite <- addn0.
                  do 2 rewrite <- app_assoc.
                  rewrite <- nth_error_app.
                  now reflexivity.
                + assumption.
              - (** Case permissions were increased by a [Freelock] event*)
                (** In this case, [evv] competes with [evk] and by the premise
                that [tr] is [spinlock_synchronized] there will be a [Spawn] or
                [Release]-[Acquire] pair between them and hence between [evk]
                and [evj] as well *)
                assert (Hcompeteskj: competes evk evv).
                { repeat split; eauto.
                  - rewrite Hthreadv.
                    now auto.
                  - unfold sameLocation.
                    destruct (location evv) as [[[bv ofsv] szv]|]; try (by exfalso).
                    destruct Hloc_v as [Heqb Hintvv].
                    simpl in Heqb. subst.
                    rewrite Hloc_k.
                    split; auto.
                    exists ofs.
                    split; now auto.
                  - destruct evv as [? evv | ? evv];
                      destruct evv; simpl in Hactionv; simpl;
                        try (by exfalso);
                        now auto.
                  - intros.
                    exfalso.
                    destruct evv as [? evv | ? evv];
                      simpl in Hactionv;
                      destruct evv; try (discriminate);
                        try (by exfalso).
                }
                rewrite! app_assoc in Hsynchronized.
                specialize (Hsynchronized (length ((tr0 ++ pre_k)%list))
                                          (length ((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_pre_v)%list)
                                          evk evv).
                simpl in Hsynchronized.
                destruct (Hsynchronized ltac:(clear; erewrite! app_length in *; ssromega)
                                               ltac:(clear; do 4 rewrite <- app_assoc;
                                                     rewrite <- addn0;
                                                     rewrite <- nth_error_app; reflexivity)
                                                      ltac:(clear;
                                                            rewrite <- addn0;
                                                            rewrite <- app_assoc;
                                                            rewrite <- nth_error_app; reflexivity) Hcompeteskj)
                  as [[r [a [er [ea [Horderra [Horderra' [Hevr [Heva [Hactr [Hacta Hloc_ra]]]]]]]]]] |
                      [s [es [Horders [Hs Hacts]]]]].
                + (** Case there is a [Release]-[Acquire] pair between k and v*)
                  left.
                  exists r, a, er, ea.
                  repeat split; auto.
                  * clear - Horderra Horderra' Horder.
                    rewrite! app_assoc_reverse in Horderra'.
                    erewrite! app_length in *.
                    apply/andP.
                    split; now ssromega.
                  * clear - Horderra Horderra' Horder Hj_not_in_tr.
                    rewrite! app_assoc_reverse in Horderra'.
                    erewrite! app_length in *.
                    ssromega.
                  * eapply nth_error_app_inv;
                      eassumption.
                  * eapply nth_error_app_inv;
                      eassumption.
                + (** Case there is a [Spawn] event between k and v*)
                  right.
                  exists s, es.
                  repeat split; auto.
                  * clear - Horders Horder Hj_not_in_tr.
                    erewrite! app_assoc_reverse in *.
                    erewrite! app_length in *.
                    ssromega.
                  * eapply nth_error_app_inv;
                      now eauto.
              - (** Case permissions were increased by an [Acquire] event*)
                destruct Hrmap as [rmap Hlocv].
                destruct (location evv) as [[laddr sz]|] eqn: Hloc_v; try (by exfalso).
                destruct Hlocv as [Hsz [HlockRes_v Hperm_res]]; subst.
                (** [rmap] at [tp_k'] will either not exist or if it exists will be below [Readable]*)
                destruct (lockRes tp_k' laddr) as [rmap_k|] eqn:Hres_k.
                + (** By [invariant] at [tp_k'] [rmap_k !! b ofs] will be below [Readable]*)
                  assert (Hperm_rmap_k: ~ Mem.perm_order'' (rmap_k.1 !! b ofs) (Some Readable) /\
                                        ~ Mem.perm_order'' (rmap_k.2 !! b ofs) (Some Readable)).
                  { clear - Hres_k Hinvk' Hwritablek.
                    pose proof ((no_race Hinvk' _ cntk' Hres_k).1 b ofs) as [? Hcomp].
                    pose proof ((no_race Hinvk' _ cntk' Hres_k).2 b ofs) as [? Hcomp2].
                    pose proof ((thread_data_lock_coh Hinvk' cntk').2 _ _ Hres_k b ofs) as Hcoh.
                    pose proof ((locks_data_lock_coh Hinvk' _ Hres_k).1 _ cntk' b ofs) as Hcoh2.
                    destruct Hwritablek;
                    split; intros Hcontra;
                    repeat match goal with
                           | [H: Mem.perm_order'' ?X _ |- _] =>
                             destruct X; simpl in H; inv H; simpl in *
                           | [H: match ?X with _ => _ end = _ |- _] =>
                             destruct X
                           end; simpl in *;
                    try (discriminate || by exfalso).
                  }

                  assert (Hperm_incr':
                            (~ Mem.perm_order'' ((rmap_k#1) # b ofs) (Some Readable) /\
                              Mem.perm_order'' ((rmap#1) # b ofs) (Some Readable)) \/
                            (~ Mem.perm_order'' ((rmap_k#2) # b ofs) (Some Readable) /\
                              Mem.perm_order'' ((rmap#2) # b ofs) (Some Readable)))
                    by (destruct Hperm_rmap_k; destruct Hperm_res; now auto).
                  (** Then there must have soome [Release] event on that lock to
                  increase its permissions*)
                  destruct (lockRes_permission_increase_execution _ _ _ _ Hres_k HlockRes_v
                                                                  Hexec_pre_v Hperm_incr')
                    as (u & evu & Hu & Hactionu & Hlocu).
                  left.
                  exists ((length (((tr0 ++ pre_k) ++ [:: evk]) ++ post_k)%list) + u),
                  (length ((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_pre_v)%list), evu, evv.
                  repeat split.
                  * clear - Hu Hj_not_in_tr Horder.
                    erewrite! app_assoc in *.
                    erewrite! app_length in *.
                    simpl in *.
                    apply/andP.
                    move/andP:Horder=>[? ?].
                    split. now ssromega.
                    pose proof ((nth_error_Some tr_pre_v u).1 ltac:(intros Hcontra; congruence)).
                    simpl.
                    now ssromega.
                  * clear - Hj_not_in_tr.
                    erewrite! app_assoc in *;
                      erewrite! app_length in *.
                    erewrite <- Nat.le_ngt in Hj_not_in_tr.
                    simpl in *. now ssromega.
                  * do 3 rewrite <- app_assoc.
                    rewrite <- nth_error_app.
                    eapply nth_error_app_inv;
                      now eauto.
                  * do 2 rewrite <- app_assoc.
                    rewrite <- addn0.
                    rewrite <- nth_error_app.
                    reflexivity.
                  * assumption.
                  * assumption.
                  * rewrite Hloc_v Hlocu.
                    reflexivity.
                + (** Case the lock was not created at index k*)
                  (** Since the lock exists at v someone must have created it*)
                  destruct (lockRes_mklock_execution _ _ Hres_k HlockRes_v Hexec_pre_v)
                    as (tr_prew & evw & ? & ? & tp_prew & m_prew & tp_mk & m_mk
                        & Hexec_prew & Hstep_mk & Hexec_postw & Hactionw & Hlocw & Hlock_mk).
                  (** At that point it's resources would be empty. But later the
                  lock has a [Readable] permission in it, hence there must be a
                  [Release] on that lock*)
                  assert (Hperm_mk:
                            ~ Mem.perm_order'' ((empty_map, empty_map).1 !! b ofs) (Some Readable) /\
                            ~ Mem.perm_order'' ((empty_map, empty_map).2 !! b ofs) (Some Readable))
                    by (rewrite empty_map_spec; simpl; now auto).
                  destruct (multi_fstep_trace_monotone Hexec_postw) as [tr_post_mk Heq_tr].
                  rewrite! app_assoc_reverse in Heq_tr.
                  do 4 apply app_inv_head in Heq_tr; subst.
                  rewrite! app_assoc in Hexec_postw.
                  assert (Hperm_res_incr':
                            (~ Mem.perm_order'' (((empty_map, empty_map)#1) # b ofs)
                              (Some Readable) /\
                              Mem.perm_order'' ((rmap#1) # b ofs) (Some Readable)) \/
                            (~ Mem.perm_order'' (((empty_map, empty_map)#2) # b ofs)
                               (Some Readable) /\
                              Mem.perm_order'' ((rmap#2) # b ofs) (Some Readable)))
                    by (destruct Hperm_mk; destruct Hperm_res; now auto).
                  destruct (lockRes_permission_increase_execution _ _ _ _ Hlock_mk HlockRes_v
                                                                  Hexec_postw Hperm_res_incr')
                    as (u & evu & Hu & Hactionu & Hlocu).
                  left.
                  exists (length (((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_prew ++ [:: evw])%list) + u),
                  (length ((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_prew ++ [:: evw] ++
                                                                    tr_post_mk) %list), evu, evv.
                  repeat split.
                  * clear - Hu Hj_not_in_tr Horder.
                    erewrite! app_assoc in *.
                    erewrite! app_length in *.
                    simpl in *.
                    apply/andP.
                    move/andP:Horder=>[? ?].
                    split. now ssromega.
                    pose proof ((nth_error_Some tr_post_mk u).1 ltac:(intros Hcontra; congruence)).
                    simpl.
                    now ssromega.
                  * clear - Hj_not_in_tr.
                    erewrite! app_assoc in *;
                      erewrite! app_length in *.
                    erewrite <- Nat.le_ngt in Hj_not_in_tr.
                    simpl in *. now ssromega.
                  * rewrite! app_assoc.
                    do 3 rewrite <- app_assoc.
                    rewrite <- nth_error_app.
                    eapply nth_error_app_inv;
                      now eauto.
                  * do 2 rewrite <- app_assoc.
                    rewrite <- addn0.
                    rewrite <- nth_error_app.
                    reflexivity.
                  * assumption.
                  * assumption.
                  * rewrite Hloc_v Hlocu.
                    reflexivity.
            }
          }
      
        { (** Case [thread_id evj] was not in the threadpool*)
          Lemma thread_spawn_step:
            forall U tr tp m U' tp' m' tr' tidn
              (cnt: ~ containsThread tp tidn)
              (cnt': containsThread tp' tidn)
              (Hstep: FineConc.MachStep the_ge (U, tr, tp) m (U', tr ++ tr', tp') m'),
            exists ev,
              tr' = [:: ev] /\ action ev = Spawn.
          Proof.
            intros;
            inv Hstep; simpl in *;
            try apply app_eq_nil in H4;
            try inv Htstep;
            destruct U; inversion HschedN; subst; pf_cleanup;
            try (inv Hhalted);
            try  (exfalso; by eauto);
            apply app_inv_head in H5; subst.
            eexists; simpl; split;
            now eauto.
          Qed.

          Lemma thread_spawn_execution:
            forall U tr tpi mi U' tr' tpj mj
              tidn
              (cnti: ~ containsThread tpi tidn)
              (cntj: containsThread tpj tidn)
              (Hexec: multi_fstep (U, tr, tpi) mi (U', tr ++ tr', tpj) mj),
            exists tr_pre evu U'' U''' tp_pre m_pre tp_inc m_inc,
              multi_fstep (U, tr, tpi) mi (U'', tr ++ tr_pre, tp_pre) m_pre /\
              FineConc.MachStep the_ge (U'', tr ++ tr_pre, tp_pre) m_pre
                                (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc /\
              multi_fstep (U''', tr ++ tr_pre ++ [:: evu], tp_inc) m_inc
                          (U', tr ++ tr',tpj) mj /\
              action evu = Spawn.
          Proof.
            induction U as [|tid' U]; intros.
            - inversion Hexec. apply app_eq_nil in H3; subst.
              pf_cleanup. by congruence.
            - inversion Hexec.
              + apply app_eq_nil in H3; subst.
                pf_cleanup;
                  by congruence.
              + apply app_inv_head in H6; subst.
                destruct (containsThread_dec tidn tp') as [cnt' | not_cnt'].
                * destruct (thread_spawn_step _ cnti cnt' H8) as [ev [? ?]].
                  subst.
                  exists [:: ], ev, (tid' :: U)%SEQ, U, tpi, mi, tp', m'.
                  split.
                  rewrite app_nil_r. constructor.
                  split.
                  simpl.
                  rewrite app_nil_r.
                  assumption.
                  split. simpl; assumption.
                  assumption.
                * erewrite! app_assoc in *.
                  destruct (IHU _ _ _ _ _ _ _ _ not_cnt' cntj H9)
                    as (tr_pre & evu & U'' & U''' & tp_pre & m_pre & tp_inc & m_inc
                        & Hexec_pre & Hstep & Hexec_post).
                  exists (tr'0 ++ tr_pre), evu, U'', U''', tp_pre, m_pre, tp_inc, m_inc.
                  erewrite! app_assoc in *.
                  repeat (split; eauto using multi_fstep).
                  rewrite <- app_assoc.
                  econstructor; eauto.
                  rewrite! app_assoc; eauto.
          Qed.
            

          destruct (thread_spawn_execution _ Hnot_contained cntj Hexec')
            as (tr_pre_spawn & evv & ? & ? & tp_pre_spawn & m_pre_spawn &
                tp_spanwed & m_spanwed & Hexec_pre_spawn & Hstep_spawn &
                Hexec_post_spawn & Hactionv).
          right.
          destruct (multi_fstep_trace_monotone Hexec_post_spawn) as [tr''0 Heq].
          rewrite! app_assoc_reverse in Heq.
          do 4 apply app_inv_head in Heq; subst.
          rewrite! app_assoc.
          exists (length ((((tr0 ++ pre_k) ++ [:: evk]) ++ post_k) ++ tr_pre_spawn)%list), evv.
          repeat split.
          + clear - Hj_not_in_tr Horder.
            erewrite! app_assoc in *.
            erewrite! app_length in *.
            simpl.
            apply/andP.
            split.
            now ssromega.
            erewrite <- Nat.le_ngt in Hj_not_in_tr.
            simpl in *.
            now ssromega.
          + rewrite <- addn0.
            do 2 rewrite <- app_assoc.
            rewrite <- nth_error_app.
            now reflexivity.
          + assumption.
        }
    Qed.

    (** FineConc is spinlock well-synchronized, strengthened version of the theorem*)
     Theorem fineConc_spinlock_strong:
      forall U U0 U' tr tr' tp m tp0 m0 tp' m'
        (Hsynced: spinlock_synchronized tr)
        (Hexec0: multi_fstep (U0, [::], tp0) m0 (U, tr, tp) m)
        (Hexec: multi_fstep (U, tr, tp) m (U', tr ++ tr', tp') m'),
        spinlock_synchronized (tr ++ tr').
    Proof.
      intro.
      induction U; intros.
      - inversion Hexec. 
        rewrite <- app_nil_r in H3 at 1;
          apply app_inv_head in H3;
          subst.
        rewrite <- catA.
        rewrite! cats0.
        assumption.
      - inversion Hexec.
        + rewrite <- app_nil_r in H3 at 1;
            apply app_inv_head in H3;
            subst.
          rewrite <- catA.
          rewrite! cats0.
          assumption.
        + subst.
          apply app_inv_head in H6; subst.
          pose proof H8 as Hfstep.
          eapply fineConc_step_synchronized in H8; eauto.
          specialize (IHU U0 U' (tr ++ tr'0) tr'').
          do 2 rewrite <- app_assoc in IHU.
          rewrite <- app_assoc_l.
          eapply IHU with (tp0 := tp0) (tp := tp'0) (m0 := m0) (m := m'0).
          eassumption.
          rewrite <- app_nil_l with (l := tr ++ tr'0).
          eapply multi_fstep_snoc; eauto.
          eauto.
    Qed.

    (** FineConc is spinlock well-synchronized*)
    Corollary fineConc_spinlock:
      forall U tr tp m tp' m'
        (Hexec: multi_fstep (U, [::], tp) m ([::], tr, tp') m'),
        spinlock_synchronized tr.
    Proof.
      intros.
      do 2 rewrite <- app_nil_l.
      eapply fineConc_spinlock_strong with (U0 := U) (tp0 := tp) (m0 := m);
        eauto.
      simpl.
      intros ? ? ? ? ? Hcontra.
      rewrite nth_error_nil in Hcontra. discriminate.
      simpl.
      now econstructor.
    Qed.
                                                                                      

                                                                                      