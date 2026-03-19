-module(neural_link_ffi).
-export([exec_command/1, read_line/0]).

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

collect_output(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_output(Port, <<Acc/binary, Data/binary>>);
        {Port, {exit_status, 0}} ->
            {ok, Acc};
        {Port, {exit_status, _N}} ->
            {error, Acc}
    after 10000 ->
        catch port_close(Port),
        {error, <<"timeout">>}
    end.
