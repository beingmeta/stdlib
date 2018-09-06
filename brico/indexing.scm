;;; -*- Mode: Scheme; Character-encoding: utf-8; -*-
;;; Copyright (C) 2005-2018 beingmeta, inc.  All rights reserved.

(in-module 'brico/indexing)
;;; Functions for generating BRICO indexes

(use-module '{brico texttools logger})

(define %nosubst '{indexinfer default-frag-window})

;; When true, this assumes that the lattice has been indexed,
;;  so that closures can be computed based on their inverses
;;  (e.g. (get x genls*)== (?? @?specls* x))
(define indexinfer #t)

(define indexinfer-config
  (slambda (var (val 'unbound))
    (cond ((eq? val 'unbound) indexinfer)
	  ((equal? val indexinfer)
	   indexinfer)
	  (else
	   (set! indexinfer val)))))
(config-def! 'indexinfer indexinfer-config)

;;; Indexing functions

;;; This optionally takes a slotmap as an index, where the slotmap
;;;  maps slot values to indexes.
(defambda (index-relation index-spec frame slotids (values) (inverse #f))
  (do-choices (slotid slotids)
    (let* ((index (if (or (index? index-spec) (hashtable? index-spec)) 
		      index-spec
		      (try (get index-spec slotid) (get index-spec '%default))))
	   (inverse (and inverse
			 (try (pickoids inverse)
			      (get slotid 'inverse)
			      #f)))
	   (inv-index (and inverse
			   (if (or (index? index-spec) (hashtable? index-spec))
			       index-spec
			       (try (get index-spec inverse) (get index-spec '%default))))))
      (cond ((fail? index)
	     (logwarn |NoIndex| "No index found for slot " slotid))
	    ((bound? values)
	     (index-frame index frame slotid values)
	     (when inverse 
	       (index-frame inv-index (pickoids values) inverse frame)))
	    (inverse
	     (let ((values (get frame slotid)))
	       (index-frame index frame slotid values)
	       (index-frame inv-index (pickoids values) inverse frame)))
	    (else (index-frame index frame slotid))))))
(defambda (unindex frame slot value (index #f))
  (do-choices (slot slot)
    (do-choices (value value)
      (if (not index)
	  (do-choices (index (config 'background))
	    (when (%test index (cons slot value) frame)
	      (message "Dropping references from " index)
	      (drop! index  (cons slot value) frame)))
	  (when (%test index (cons slot value) frame)
	    (drop! index  (cons slot value) frame))))))

;;; Slot indexing functions

(define (stem-compound string)
  (seq->phrase (map porter-stem (words->vector string))))

(define (dedash string)
  (tryif (position #\- string)
    (choice (string-subst string "-" " " )
	    (string-subst string "-" ""))))

(defambda (index-string index frame slot (value #f) (frag #f))
  (do-choices slot
    (let* ((values (stdspace (pickstrings (if value value (get frame slot)))))
	   (expvalues (choice values (basestring values)))
	   (normvalues (capitalize (pick expvalues somecap?))))
      ;; By default, we index strings under their direct values, under
      ;;  their values without diacritics, and under versions with normalized
      ;;  capitalization.  Normalizing capitalization makes all elements of a
      ;;  compound be uppercase and makes oddly capitalized terms (e.g. iTunes)
      ;;  be lowercased.
      (index-relation index frame slot (choice expvalues normvalues))
      (index-relation index frame slot (dedash normvalues))
      (index-relation index frame slot
		      (choice (pick (metaphone (choice values normvalues) #t) length>1)
			      (pick (metaphone+ (choice values normvalues) #t) length>1)))
      (index-relation index frame slot (pick (soundex (choice values normvalues) #t) length>1))
      (when frag (index-frags index frame slot values 1 #f)))))

(defambda (index-string/keys value)
  (let* ((values (stdspace value))
	 (expvalues (choice values (basestring values)))
	 (normvalues (capitalize (pick expvalues somecap?))))
    ;; By default, we index strings under their direct values, under
    ;;  their values without diacritics, and under versions with normalized
    ;;  capitalization.  Normalizing capitalization makes all elements of a
    ;;  compound be uppercase and makes oddly capitalized terms (e.g. iTunes)
    ;;  be lowercased.
    (choice expvalues normvalues
	    (pick (metaphone (choice values normvalues) #t) length>1)
	    (pick (soundex (pick (reject (choice values normvalues) compound?)
			     length < 11)
			   #t)
	      length>1))))

(defambda (index-name index frame slot (value #f) (window default-frag-window))
  (let* ((values (downcase (stdspace (if value value (get frame slot)))))
	 (expvalues (choice values (basestring values))))
    (index-relation index frame slot expvalues)
    (when window
      (index-frags index frame slot expvalues window))))

(define (index-frame* index frame slot base (inverse #f) (v))
  (default! v (get frame base))
  (index-relation index frame base v (try (get base 'inverse) #f))
  (do ((g v (difference (get g base) seen))
       (seen frame (choice g seen)))
      ((empty? g))
    (index-relation index frame slot g inverse)))*

(define (index-gloss index frame slotid (value #f))
  (let* ((wordlist (getwords (or value (get frame slotid))))
	 (gloss-words (filter-choices (word (elts wordlist))
			(< (length word) 16))))
    (index-relation index frame slotid
		    (choice gloss-words (porter-stem gloss-words)))))

;;; Indexing string fragments

(define default-frag-window #f)

(define fragwindow-config
  (slambda (var (val 'unbound))
    (cond ((eq? val 'unbound) default-frag-window)
	  ((equal? val default-frag-window) default-frag-window)
	  ((not val) (set! default-frag-window #f))
	  ((and (number? val) (exact? val) (> val 0))
	   (set! default-frag-window #f))
	  (else (warning "Invalid fragment window" val)))))
(config-def! 'fragwindow fragwindow-config)

(define (metaphone1 w)
  (pick (tryif (and (not (uppercase? w)) (> (length w) 3))
	  (metaphone w #t))
    length>1))
(define (metaphone2 w)
  (pick (tryif (and (not (uppercase? w)) (> (length w) 5))
	  (metaphone (porter-stem w) #t))
    length>1))

(define (trimwordvec v)
  (if (or (position "" v)  (position #"" v) (position #{} v))
      {}
      v))

(defambda (index-frags index frame slot values window (phonetic #f) (compounds))
  (set! compounds (pick values compound-string?))
  (when (exists? compounds)
    (let* ((stdcompounds (basestring compounds))
	   (wordv (words->vector compounds))
	   (swordv (words->vector stdcompounds)))
      (index-relation index frame slot
		      (vector->frags (trimwordvec (choice wordv swordv)) window))
      (when phonetic
	(index-relation index frame slot
			(vector->frags (trimwordvec (map metaphone1 wordv))))
	(index-relation index frame slot
			(vector->frags (trimwordvec (map metaphone2 wordv))))))))

(defambda (index-frags/keys value (window 1) (phonetic #t))
  (let* ((values (stdstring value))
	 (compounds (pick values compound?))
	 (stdcompounds (basestring compounds))
	 (wordv (words->vector compounds))
	 (swordv (words->vector stdcompounds)))
    (choice (vector->frags (trimwordvec (choice wordv swordv)) window)
	    (tryif phonetic (vector->frags (trimwordvec (map metaphone1 wordv))))
	    (tryif phonetic (vector->frags (trimwordvec (map metaphone2 wordv)))))))

;;; Frame indexing functions

;; These are slotids whose indexed values should include implications
(define implied-slotids
  '{@1/2c274{PARTOF}
    @1/2c277{INGREDIENT-OF}
    @1/2c279{MEMBER-OF}
    @1/2c27e{IMPLIES}})

;; These are slotids whose inverses should also be indexed
(define inverted-slotids
  {@1/10{DIFFTERMS}
   @1/3f65f{ENTAILS}
   @1/2c27d{DISJOINT}
   @1/2d9e9{=IS=}})

;; These are various other slotids which are useful to index
;;(define misc-slotids '{PERTAINYM REGION COUNTRY @1/2c27e{IMPLIES}})

(define (index-concept index concept)
  (index-brico index concept)  
  (index-words index concept)
  (index-relations index concept)
  (index-refterms index concept)
  (index-lattice index concept)
  (index-analytics index concept))

(define wordform-slotids '{word of language rank type sensenum})

(define (index-core index frame)
  (index-relation index frame
		  '{type sensecat fips-code source dsg wikid
		    topic_domain region_domain usage_domain})
  (when (and (or (%test frame 'words) (%test frame '%words))
	     (ambiguous? (get frame 'sensecat)))
    (index-relation index frame 'sensecat 'ambiguous))
  (when (and (test frame '{%words words word type})
	     (not (test frame 'sensecat)))
    (index-relation index frame 'sensecat 'senseless))
  (when (test frame '%index)
    (index-relation index frame (pick (get frame '%index) {oid? symbol?})))
  (index-relation index frame '%id (get frame '{%mnemonics %mnemonic}))
  (when (or (test frame 'type 'slot) (test frame 'type 'get-methods))
    (index-relation index frame '%id))
  (index-relation index frame '%ids)
  (index-relation index frame '%mnemonic)
  (index-relation index frame '%mnemonics)
  (index-relation index frame '{key through slots inverse @1/2c27a}))

(define (index-wordform index frame)
  (when (test frame 'type 'wordform)
    (index-frame index frame wordform-slotids)))

(define (index-brico index frame)
  (if (empty? (getslots frame))
      (index-frame index frame 'status 'deleted)
      (if (test frame 'source @1/1)
	  ;; We minimally index the Roget frames, since they tend
	  ;;  to mostly get in the way and often be archaic
	  (index-relation index frame '{type source})
	  (begin
	    (index-core index frame)
	    (when (test frame 'type 'language)
	      (index-frame index frame
		'{langid language iso639/1 iso639/B iso639/T}))
	    (when (test frame '{get-methods test-methods add-effects drop-effects})
	      (index-frame index frame
		'{get-methods test-methods add-effects drop-effects
		  key through derivation inverse closure-of slots
		  primary-slot index %id}))))))

(define (index-words index concept)
  (index-string index concept english (get concept 'words))
  (index-name index concept 'names (get concept 'names))
  (index-name index concept 'names
	      (pick  (cdr (get concept '%words)) capitalized?))
  (do-choices (xlation (pick (get concept '%words) pair?))
    (let ((lang (get language-map (car xlation))))
      (index-string index concept lang (cdr xlation))))
  (do-choices (xlation (pick (get concept '%words) slotmap?))
    (do-choices (langid (getkeys xlation))
      (let ((lang (get language-map langid)))
	(index-string index concept lang (get xlation langid)))))
  (do-choices (xlation (pick (get concept '%norms) pair?))
    (let ((lang (get norm-map (car xlation))))
      (index-string index concept lang (cdr xlation))))
  (do-choices (xlation (pick (get concept '%norms) slotmap?))
    (do-choices (langid (getkeys xlation))
      (let ((lang (get norm-map langid)))
	(index-string index concept lang (get xlation langid)))))
  (do-choices (xlation (pick (get concept '%indicators) pair?))
    (let ((lang (get indicator-map (car xlation))))
      (index-string index concept lang (cdr xlation))))
  (do-choices (xlation (pick (get concept '%indicators) slotmap?))
    (do-choices (langid (getkeys xlation))
      (let ((lang (get indicator-map langid)))
	(index-string index concept lang (get xlation langid))))))

(define (getallvalues concept slotids)
  (choice (%get concept slotids)
	  (%get concept (get* (pickoids slotids) 'slots))))

(defambda (index-genl-values index frame slot (values))
  (do-choices (slot slot)
    (let ((v (if (bound? values) values (getallvalues frame slot))))
      (when (exists? v)
	;; We index (v) to indicate that v is a stored value
	(index-relation index frame slot (choice v (list v)))
	(index-relation index frame slot (?? specls* v))))))

(define (index-relations index concept)
  (do-choices (slotid inverted-slotids)
    (index-relation index concept slotid (getallvalues concept slotid)
		    (and (oid? slotid) (try (get slotid 'inverse) #f))))
  ;; (do-choices (slotid implied-slotids) (index-implied index concept slotid (getallvalues concept slotid)))
  ;; (do-choices (slotid misc-slotids) (index-relation index concept slotid (%get concept slotid)))
  )

(define (index-refterms index concept)
  (index-relation index concept refterms (%get concept refterms) #f)
  (index-relation index concept sumterms (%get concept sumterms) /sumterms)
  ;; This handles the case of explicit inverse pointers.
  ;;  If we want to add a pointer R from X to Y and
  ;;   we can't or don't want to modify X, we store
  ;;   an explicit inverse ((inv R) Y)=X which will be
  ;;   found by the inverse inference methods.
  ;; Otherwise, we don't index the @?defines and @?referenced
  ;;  slots because it is easier to just get @?sumterms
  ;;  and @?refterms.
  (when (%test concept /sumterms)
    (index-relation index (%get concept /sumterms) sumterms concept)
    (index-relation index concept /sumterms (%get concept /sumterms)))
  (when (%test concept /refterms)
    (index-relation index (%get concept references) refterms concept)
    (index-relation index concept references (%get concept references))))

(define (index-lattice concept index)
  (index-frame* index concept genls* genls specls*)
  (index-frame* index concept partof* partof parts*)
  (index-frame* index concept memberof* memberof members*)
  (index-frame* index concept ingredientof* ingredientof ingredients*))

(define (index-analytics index concept)
  ;; ALWAYS is transitive
  (index-frame* index concept always always /always)
  ;; SOMETIMES is symmetric
  (index-frame index concept sometimes)
  (index-frame index (get concept sometimes) sometimes concept)
  ;; NEVER is symmetric
  (index-frame index concept never)
  (index-frame index (get concept never) never concept)
  (index-frame index concept somenot)
  (index-frame index (get concept somenot) /somenot concept)
  (index-frame index concept commonly)
  (index-frame index concept rarely)
  ;; index some inferred values, relying on the lattice relations
  ;; which were indexed above
  (let ((s (get concept sometimes))
	(c (get concept commonly))
	(n (get concept never)))
    (when (exists? s)
      (index-frame index concept sometimes (list s))
      (index-frame index s sometimes (list concept))
      (index-frame index concept
	sometimes (find-frames index /always s))
      (unless (test concept 'type 'individual)
	(index-frame index (find-frames index /always s)
	  sometimes concept)))
    (when (exists? n)
      (index-frame index concept never (list n))
      (index-frame index n never (list concept))
      (index-frame index (find-frames index /always n)
	never concept))
    (when (exists? c)
      ;; This indexes concept as commonly being all of the always of c
      (index-frame index concept
	commonly (find-frames index /always c)))))

(define (indexer index concept (slotids) (values))
  (if (bound? slotids)
      (if (bound? values)
	  (index-relation index concept slotids values)
	  (index-relation index concept slotids))
      (index-concept index concept)))

(define (next-expansion expansions visited)
  (let ((oids (get expansions (getkeys expansions))))
    (prefetch-oids! oids)
    (hashset-add! visited oids)
    (let ((table (make-hashtable)))
      (do-choices (slotid (getkeys expansions))
	(prefetch-keys! (cons (get slotid inverse) (get expansions slotid)))
	(let ((next (reject (get (get expansions slotid) slotid)
		      visited)))
	  (when (exists? next)
	    (add! table slotid next))))
      (if (exists? (getkeys table)) table (fail)))))

(define (prefetch-expansions oids slotids)
  (let ((visited (choice->hashset oids))
	(next (make-hashtable)))
    (prefetch-oids! oids)
    (prefetch-keys! (cons (get (pick slotids oid?) 'inverse) oids))
    (do-choices (slotid slotids)
      (add! next slotid (get oids slotid)))
    (do ((scan next (next-expansion (qc scan) visited)))
	((fail? scan)))))

(define (indexer-prefetch-slotids!)
  (prefetch-oids! (choice implied-slotids inverted-slotids
			  (get language-map (getkeys language-map))
			  (get norm-map (getkeys norm-map))
			  (get indicator-map (getkeys indicator-map))
			  (get gloss-map (getkeys gloss-map)))))

(define (indexer/prefetch oids)
  (prefetch-oids! oids)
  (prefetch-keys! (cons (choice refterms /refterms) oids))
  (let ((kovalues (%get oids implied-slotids)))
    (prefetch-expansions (qc kovalues) genls)))

(define (index-lattice/prefetch oids)
  (prefetch-oids! oids)
  (prefetch-expansions
   (qc oids) (qc genls partof memberof ingredientof)))

;;; EXPORTS

;;; These are helpful for indexing data BRICO-style or indexing
;;;  data which use BRICO.
(module-export!
 '{
   index-relation
   indexer unindex
   index-string index-name index-frags index-frame*
   index-string/keys index-frags/keys index-gloss
   index-implied-values})

;;; These all support indexing BRICO itself
(module-export!
 '{index-brico
   index-core index-brico index-wordform
   index-words index-relations index-lattice
   index-analytics
   index-refterms
   index-concept
   indexer/prefetch
   index-lattice/prefetch
   indexer-prefetch-slotids!})

