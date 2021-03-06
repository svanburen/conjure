(module conjure.client.clojure.nrepl.action
  {require {client conjure.client
            text conjure.text
            extract conjure.extract
            editor conjure.editor
            ll conjure.linked-list
            log conjure.log
            fs conjure.fs
            eval conjure.aniseed.eval
            str conjure.aniseed.string
            nvim conjure.aniseed.nvim
            view conjure.aniseed.view
            config conjure.client.clojure.nrepl.config
            state conjure.client.clojure.nrepl.state
            server conjure.client.clojure.nrepl.server
            ui conjure.client.clojure.nrepl.ui
            a conjure.aniseed.core}})

(defn- session-type? [st]
  (when (a.string? st)
    (a.some
      #(= st $1)
      [:Clojure
       :ClojureScript
       :ClojureCLR
       :Unknown])))

(defn display-session-type []
  (server.eval
    {:code (.. "#?("
               (str.join
                 " "
                 [":clj 'Clojure"
                  ":cljs 'ClojureScript"
                  ":cljr 'ClojureCLR"
                  ":default 'Unknown"])
               ")")}
    (server.with-all-msgs-fn
      (fn [msgs]
        (let [session-type (a.some #(a.get $1 :value) msgs)]
          (if (session-type? session-type)
            (ui.display [(.. "; Session type: " session-type)]
                        {:break? true})
            (do
              (ui.display ["; Couldn't determine session type."]
                          {:break? true})
              (a.run! ui.display-result msgs))))))))

(defn passive-ns-require []
  (when config.eval.auto-require?
    (server.with-conn-or-warn
      (fn [conn]
        (let [ns (extract.context)]
          (when ns
            (server.eval
              {:code (.. "(clojure.core/require '" ns ")")}
              (fn [])))))
      {:silent? true})))

(defn connect-port-file []
  (let [port (-?>> config.connection.port-files
                   (a.map fs.resolve)
                   (a.some a.slurp)
                   (tonumber))]
    (if port
      (do
        (server.connect
          {:host config.connection.default-host
           :port port})
        (passive-ns-require))
      (ui.display ["; No nREPL port file found"] {:break? true}))))

(defn connect-host-port [...]
  (let [args [...]]
    (server.connect
      {:host (if (= 1 (a.count args))
               config.connection.default-host
               (a.first args))
       :port (tonumber (a.last args))})
    (passive-ns-require)))

(defn- eval-cb-fn [opts]
  (fn [resp]
    (when (and (a.get opts :on-result)
               (a.get resp :value))
      (opts.on-result resp.value))

    (let [cb (a.get opts :cb)]
      (if cb
        (cb resp)
        (ui.display-result resp opts)))))

(defn- in-ns [ns]
  (server.eval
    {:code (.. "(in-ns '"
               (or ns "#?(:cljs cljs.user, :default user)")
               ")")}
    (fn [])))

(defn eval-str [opts]
  (server.with-conn-or-warn
    (fn [_]
      (in-ns opts.context)
      (server.eval opts (eval-cb-fn opts)))))

(defn- with-info [opts f]
  (server.with-conn-and-op-or-warn
    :info
    (fn [conn]
      (server.send
        {:op :info
         :ns (or opts.context "user")
         :symbol opts.code
         :session conn.session}
        (fn [msg]
          (f (when (not msg.status.no-info)
               msg)))))))

(defn- java-info->lines [{: arglists-str : class : member : javadoc}]
  (a.concat
    [(str.join
       (a.concat ["; " class]
                 (when member
                   ["/" member])))]
    (when (not (a.empty? arglists-str))
      [(.. "; (" (str.join " " (text.split-lines arglists-str)) ")")])
    (when javadoc
      [(.. "; " javadoc)])))

(defn doc-str [opts]
  (in-ns opts.context)
  (server.eval
    (a.merge
      {} opts
      {:code (.. "(do (clojure.core/require 'clojure.repl)"
                 "(clojure.repl/doc " opts.code "))")})
    (server.with-all-msgs-fn
      (fn [msgs]
        (if (a.some (fn [msg]
                      (or (a.get msg :out)
                          (a.get msg :err)))
                    msgs) 
          (a.run!
            #(ui.display-result
               $1
               {:simple-out? true :ignore-nil? true})
            msgs)
          (do
            (ui.display ["; No results, checking CIDER's info op"])
            (with-info
              opts
              (fn [info]
                (if
                  (a.nil? info)
                  (ui.display ["; Nothing found via CIDER's info either"])

                  info.javadoc
                  (ui.display (java-info->lines info))

                  info.doc
                  (ui.display
                    (a.concat
                      [(.. "; " info.ns "/" info.name)
                       (.. "; (" info.arglists-str ")")]
                      (text.prefixed-lines info.doc "; ")))

                  (ui.display
                    (a.concat
                      ["; Unknown result, it may still be helpful"]
                      (text.prefixed-lines (view.serialise info) "; "))))))))))))

(defn- nrepl->nvim-path [path]
  (if
    (text.starts-with path "jar:file:")
    (string.gsub path "^jar:file:(.+)!/?(.+)$"
                 (fn [zip file]
                   (.. "zipfile:" zip "::" file)))

    (text.starts-with path "file:")
    (string.gsub path "^file:(.+)$"
                 (fn [file]
                   file))

    path))

(defn def-str [opts]
  (with-info
    opts
    (fn [info]
      (if
        (a.nil? info)
        (ui.display ["; No definition information found"])

        info.candidates
        (ui.display
          (a.concat
            ["; Multiple candidates found"]
            (a.map #(.. $1 "/" opts.code) (a.keys info.candidates))))

        info.javadoc
        (ui.display ["; Can't open source, it's Java"
                     (.. "; " info.javadoc)])

        info.special-form
        (ui.display ["; Can't open source, it's a special form"
                     (when info.url (.. "; " info.url))])

        (and info.file info.line)
        (let [column (or info.column 1)
              path (nrepl->nvim-path info.file)]
          (editor.go-to path info.line column)
          (ui.display [(.. "; " path " [" info.line " " column "]") ]
                      {:suppress-hud? true}))

        (ui.display ["; Unsupported target"
                     (.. "; " (a.pr-str info))])))))

(defn eval-file [opts]
  (server.eval
    (a.assoc opts :code (.. "(#?(:cljs 'cljs.core/load-file"
                            " :default 'clojure.core/load-file)"
                            " \"" opts.file-path "\")"))
    (eval-cb-fn opts)))

(defn interrupt []
  (server.with-conn-or-warn
    (fn [conn]
      (let [msgs (->> (a.vals conn.msgs)
                      (a.filter
                        (fn [msg]
                          (= :eval msg.msg.op))))

            order-66
            (fn [{: id : session : code}]
              (server.send
                {:op :interrupt
                 :interrupt-id id
                 :session session})
              (ui.display
                [(.. "; Interrupted: "
                     (if code
                       (text.left-sample
                         code
                         (editor.percent-width
                           config.interrupt.sample-limit))
                       (.. "session (" session ")")))]
                {:break? true}))]

        (if (a.empty? msgs)
          (order-66 {:session conn.session})
          (do
            (table.sort
              msgs
              (fn [a b]
                (< a.sent-at b.sent-at)))
            (order-66 (a.get (a.first msgs) :msg))))))))

(defn- eval-str-fn [code]
  (fn []
    (nvim.ex.ConjureEval code)))

(def last-exception (eval-str-fn "*e"))
(def result-1 (eval-str-fn "*1"))
(def result-2 (eval-str-fn "*2"))
(def result-3 (eval-str-fn "*3"))

(defn view-source []
  (let [word (a.get (extract.word) :content)]
    (when (not (a.empty? word))
      (ui.display [(.. "; source (word): " word)] {:break? true})
      (eval-str
        {:code (.. "(clojure.core/require 'clojure.repl)"
                   "(clojure.repl/source " word ")")
         :context (extract.context)
         :cb #(ui.display-result
                $1
                {:raw-out? true
                 :ignore-nil? true})}))))

(defn clone-current-session []
  (server.with-conn-or-warn
    (fn [conn]
      (server.clone-session (a.get conn :session)))))

(defn clone-fresh-session []
  (server.with-conn-or-warn
    (fn [conn]
      (server.clone-session))))

(defn close-current-session []
  (server.with-conn-or-warn
    (fn [conn]
      (let [session (a.get conn :session)]
        (a.assoc conn :session nil)
        (ui.display [(.. "; Closed current session: " session)]
                    {:break? true})
        (server.close-session
          session server.assume-or-create-session)))))

(defn display-sessions [cb]
  (server.with-sessions
    (fn [sessions]
      (ui.display-given-sessions sessions cb))))

(defn close-all-sessions []
  (server.with-sessions
    (fn [sessions]
      (a.run! server.close-session sessions)
      (ui.display [(.. "; Closed all sessions (" (a.count sessions)")")]
                  {:break? true})
      (server.clone-session))))

(defn- cycle-session [f]
  (server.with-conn-or-warn
    (fn [conn]
      (server.with-sessions
        (fn [sessions]
          (if (= 1 (a.count sessions))
            (ui.display ["; No other sessions"] {:break? true})
            (let [session (a.get conn :session)]
              (->> sessions
                   (ll.create)
                   (ll.cycle)
                   (ll.until #(f session $1))
                   (ll.val)
                   (server.assume-session)))))))))

(defn next-session []
  (cycle-session
    (fn [current node]
      (= current (->> node (ll.prev) (ll.val))))))

(defn prev-session []
  (cycle-session
    (fn [current node]
      (= current (->> node (ll.next) (ll.val))))))

(defn select-session-interactive []
  (server.with-sessions
    (fn [sessions]
      (if (= 1 (a.count sessions))
        (ui.display ["; No other sessions"] {:break? true})
        (ui.display-given-sessions
          sessions
          (fn []
            (nvim.ex.redraw_)
            (let [n (nvim.fn.str2nr (extract.prompt "Session number: "))]
              (if (<= 1 n (a.count sessions))
                (server.assume-session (a.get sessions n))
                (ui.display ["; Invalid session number."])))))))))

(defn run-all-tests []
  (ui.display ["; run-all-tests"] {:break? true})
  (server.eval
    {:code "(clojure.core/require 'clojure.test) (clojure.test/run-all-tests)"}
    #(ui.display-result
       $1
       {:simple-out? true
        :ignore-nil? true})))

(defn- run-ns-tests [ns]
  (when ns
    (ui.display [(.. "; run-ns-tests: " ns)]
                {:break? true})
    (server.eval
      {:code (.. "(clojure.core/require 'clojure.test)"
                 "(clojure.test/run-tests '" ns ")")}
      #(ui.display-result
         $1
         {:simple-out? true
          :ignore-nil? true}))))

(defn run-current-ns-tests []
  (run-ns-tests (extract.context)))

(defn run-alternate-ns-tests []
  (let [current-ns (extract.context)]
    (run-ns-tests
      (if (text.ends-with current-ns "-test")
        (string.sub current-ns 1 -6)
        (.. current-ns "-test")))))

(defn run-current-test []
  (let [form (extract.form {:root? true})]
    (when form
      (let [(test-name sub-count)
            (string.gsub form.content ".*deftest%s+(.-)%s+.*" "%1")]
        (when (and (not (a.empty? test-name)) (= 1 sub-count))
          (ui.display [(.. "; run-current-test: " test-name)]
                      {:break? true})
          (server.eval
            {:code (.. "(do (clojure.core/require 'clojure.test)"
                       "    (clojure.test/test-var"
                       "      (resolve '" test-name ")))")}
            (server.with-all-msgs-fn
              (fn [msgs]
                (if (and (= 2 (a.count msgs))
                         (= "nil" (a.get (a.first msgs) :value)))
                  (ui.display ["; Success!"])
                  (a.run! #(ui.display-result
                             $1
                             {:simple-out? true
                              :ignore-nil? true})
                          msgs))))))))))

(defn- refresh-impl [op]
  (server.with-conn-and-op-or-warn
    op
    (fn [conn]
      (server.send
        (a.merge
          {:op op
           :session conn.session}
          (a.get config :refresh))
        (fn [msg]
          (if
            msg.reloading
            (ui.display msg.reloading)

            msg.error
            (ui.display [(.. "; Error while reloading "
                             msg.error-ns)])

            msg.status.ok
            (ui.display ["; Refresh complete"])

            msg.status.done
            nil

            (ui.display-result msg)))))))

(defn refresh-changed []
  (ui.display ["; Refreshing changed namespaces"] {:break? true})
  (refresh-impl :refresh))

(defn refresh-all []
  (ui.display ["; Refreshing all namespaces"] {:break? true})
  (refresh-impl :refresh-all))

(defn refresh-clear []
  (ui.display ["; Clearing refresh state"] {:break? true})
  (server.with-conn-and-op-or-warn
    :refresh-clear
    (fn [conn]
      (server.send
        {:op :refresh-clear
         :session conn.session}
        (server.with-all-msgs-fn
          (fn [msgs]
            (ui.display ["; Clearing complete"])))))))

(defn shadow-select [build]
  (server.with-conn-or-warn
    (fn [conn]
      (ui.display [(.. "; shadow-cljs (select): " build)] {:break? true})
      (server.eval
        {:code (.. "(shadow.cljs.devtools.api/nrepl-select :" build ")")}
        ui.display-result))))

(defn piggieback [code]
  (server.with-conn-or-warn
    (fn [conn]
      (ui.display [(.. "; piggieback: " code)] {:break? true})
      (server.eval
        {:code (.. "(do (clojure.core/require 'cider.piggieback)"
                   "(cider.piggieback/cljs-repl " code "))")}
        ui.display-result))))

(defn- clojure->vim-completion [{:candidate word
                                 :type kind
                                 : ns
                                 :doc info
                                 : arglists}]
  {:word word
   :menu (str.join
           " "
           (a.concat
             [ns]
             (when arglists
               [(str.join " " arglists)])))
   :info info
   :kind (when (not (a.empty? kind))
           (string.upper
             (string.sub kind 1 1)))})

(defn- extract-completion-context [prefix]
  (let [root-form (extract.form {:root? true})]
    (when root-form
      (let [{: content : range} root-form
            lines (text.split-lines content)
            [row col] (nvim.win_get_cursor 0)
            lrow (- row (a.get-in range [:start 1]))
            line-index (a.inc lrow)
            lcol (if (= lrow 0)
                   (- col (a.get-in range [:start 2]))
                   col)
            original (a.get lines line-index)
            spliced (.. (string.sub
                          original
                          1 lcol)
                        "__prefix__"
                        (string.sub
                          original
                          (a.inc lcol)))]
        (-> lines
            (a.assoc line-index spliced)
            (->> (str.join "\n")))))))

(defn completions [opts]
  (server.with-conn-and-op-or-warn
    :complete
    (fn [conn]
      (server.send
        {:op :complete
         :session conn.session
         :ns opts.context
         :symbol opts.prefix
         :context (extract-completion-context opts.prefix)
         :extra-metadata [:arglists :doc]
         :enhanced-cljs-completion? "t"}
        (server.with-all-msgs-fn
          (fn [msgs]
            (->> (a.get (a.last msgs) :completions)
                 (a.map clojure->vim-completion)
                 (opts.cb))))))
    {:silent? true
     :else #(opts.cb [])}))

(defn out-subscribe []
  (ui.display ["; Subscribing to out"] {:break? true})
  (server.with-conn-and-op-or-warn
    :out-subscribe
    (fn [conn]
      (server.send {:op :out-subscribe}))))

(defn out-unsubscribe []
  (ui.display ["; Unsubscribing from out"] {:break? true})
  (server.with-conn-and-op-or-warn
    :out-unsubscribe
    (fn [conn]
      (server.send {:op :out-unsubscribe}))))
