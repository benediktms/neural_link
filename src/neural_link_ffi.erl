-module(neural_link_ffi).
-export([exec_command/1, exec_command_stdin/2, read_line/0, get_env/1,
         read_file/1, write_file/2, file_exists/1,
         get_home_dir/0, get_cwd/0, halt/1, shipment_dir/0]).

read_line() ->
    case io:get_line("") of
        eof -> {error, <<"eof">>};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))};
        Line when is_list(Line) -> {ok, unicode:characters_to_binary(Line)};
        Line when is_binary(Line) -> {ok, Line}
    end.

exec_command(Command) ->
    try
        Port = open_port({spawn, binary_to_list(Command)},
                         [exit_status, binary, stderr_to_stdout]),
        collect_output(Port, <<>>)
    catch
        _:Reason -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, <<"not_set">>};
        Value -> {ok, list_to_binary(Value)}
    end.

read_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} -> {ok, Bin};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

write_file(Path, Content) ->
    ok = filelib:ensure_dir(Path),
    case file:write_file(Path, Content) of
        ok -> {ok, nil};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

file_exists(Path) ->
    filelib:is_regular(Path).

get_home_dir() ->
    case os:getenv("HOME") of
        false -> {error, <<"HOME not set">>};
        Home -> {ok, list_to_binary(Home)}
    end.

get_cwd() ->
    case file:get_cwd() of
        {ok, Dir} -> {ok, list_to_binary(Dir)};
        {error, Reason} -> {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

exec_command_stdin(Command, Stdin) ->
    %% Pipe content via stdin using shell redirection from a temp file.
    %% This avoids ARG_MAX limits and the stdin-close problem with open_port
    %% (OTP has no way to close a port's stdin while keeping stdout open).
    Rand = binary:encode_hex(crypto:strong_rand_bytes(16)),
    TmpFile = binary_to_list(iolist_to_binary(
        ["/tmp/nlk_stdin_", Rand])),
    try
        ok = file:write_file(TmpFile, Stdin),
        ok = file:change_mode(TmpFile, 8#600),
        FullCommand = binary_to_list(iolist_to_binary(
            [Command, " < ", TmpFile])),
        Port = open_port({spawn, FullCommand},
                         [exit_status, binary, stderr_to_stdout]),
        Result = collect_output(Port, <<>>, 30000),
        file:delete(TmpFile),
        Result
    catch
        _:Reason ->
            file:delete(TmpFile),
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

shipment_dir() ->
    %% Derive the shipment root from the loaded neural_link ebin path.
    %% code:lib_dir(neural_link) returns .../build/erlang-shipment/neural_link
    %% We want .../build/erlang-shipment
    case code:lib_dir(neural_link) of
        {error, _} -> {error, <<"neural_link lib dir not found">>};
        Dir ->
            {ok, list_to_binary(filename:dirname(Dir))}
    end.

halt(Code) ->
    erlang:halt(Code).

collect_output(Port, Acc) ->
    collect_output(Port, Acc, 10000).

collect_output(Port, Acc, TimeoutMs) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>, TimeoutMs);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, _N}} ->
            {error, Acc}
    after TimeoutMs ->
        catch port_close(Port),
        {error, <<"timeout">>}
    end.
