if(NOT DEFINED PIKAFISH_ENGINE_INPUT
   OR NOT DEFINED PIKAFISH_ENGINE_OUTPUT)
  message(FATAL_ERROR "pikafish engine generator: missing input/output")
endif()

file(READ "${PIKAFISH_ENGINE_INPUT}" source)

set(old_text [=[void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);
    verify_network();

    threads.start_thinking(pos, states, limits);
}]=])

set(new_text [=[void Engine::go(Search::LimitsType& limits) {
    assert(limits.perft == 0);
    const auto evalFile = path_from_utf8(std::string(options["EvalFile"]));
    if (networkFile.current != evalFile)
    {
        if (onVerifyNetwork)
            onVerifyNetwork("PIKAFISH_NNUE_LOAD_FAILED");
        updateContext.onBestmove("(none)", "");
        return;
    }
    verify_network();

    threads.start_thinking(pos, states, limits);
}]=])

string(FIND "${source}" "${old_text}" old_index)
if(old_index EQUAL -1)
  string(FIND "${source}" "${new_text}" new_index)
  if(new_index EQUAL -1)
    message(FATAL_ERROR
      "pikafish engine generator: upstream Engine::go no longer matches the reviewed patch")
  endif()
  set(result "${source}")
else()
  string(REPLACE "${old_text}" "${new_text}" result "${source}")
endif()

get_filename_component(output_dir "${PIKAFISH_ENGINE_OUTPUT}" DIRECTORY)
file(MAKE_DIRECTORY "${output_dir}")
file(WRITE "${PIKAFISH_ENGINE_OUTPUT}" "${result}")
