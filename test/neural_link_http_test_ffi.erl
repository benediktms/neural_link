-module(neural_link_http_test_ffi).
-export([http_post/3, http_get/2]).

http_post(Url, Body, Headers) ->
    _ = inets:start(),
    _ = ssl:start(),
    HttpHeaders = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    Request = {binary_to_list(Url), HttpHeaders, "application/json", Body},
    case httpc:request(post, Request, [{timeout, 10000}], [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, RespHeaders, RespBody}} ->
            GleamHeaders = [{list_to_binary(K), list_to_binary(V)} || {K, V} <- RespHeaders],
            {ok, {StatusCode, RespBody, GleamHeaders}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.

http_get(Url, Headers) ->
    _ = inets:start(),
    _ = ssl:start(),
    HttpHeaders = [{binary_to_list(K), binary_to_list(V)} || {K, V} <- Headers],
    Request = {binary_to_list(Url), HttpHeaders},
    case httpc:request(get, Request, [{timeout, 10000}], [{body_format, binary}]) of
        {ok, {{_, StatusCode, _}, RespHeaders, RespBody}} ->
            GleamHeaders = [{list_to_binary(K), list_to_binary(V)} || {K, V} <- RespHeaders],
            {ok, {StatusCode, RespBody, GleamHeaders}};
        {error, Reason} ->
            {error, list_to_binary(io_lib:format("~p", [Reason]))}
    end.
