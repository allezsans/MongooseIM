-module(mod_http_upload_SUITE).
-compile(export_all).
-include_lib("escalus/include/escalus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("exml/include/exml.hrl").

-define(NS_XDATA, <<"jabber:x:data">>).
-define(NS_HTTP_UPLOAD, <<"urn:xmpp:http:upload">>).
-define(S3_HOSTNAME, "http://bucket.s3-eu-east-25.example.com").
-define(S3_OPTS,
        [
         {max_file_size, 1234},
         {s3, [
               {bucket_url, ?S3_HOSTNAME},
               {region, "eu-east-25"},
               {access_key_id, "AKIAIAOAONIULXQGMOUA"},
               {secret_access_key, "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"}
              ]}
        ]).

%%--------------------------------------------------------------------
%% Suite configuration
%%--------------------------------------------------------------------

all() ->
    [{group, mod_http_upload_s3}, {group, unset_size}].

groups() ->
    [{unset_size, [], [does_not_advertise_max_size_if_unset]},
     {mod_http_upload_s3, [], [
                               http_upload_item_discovery,
                               http_upload_feature_discovery,
                               advertises_max_file_size,
                               request_slot,
                               rejects_set_iq,
                               get_url_ends_with_filename,
                               urls_contain_s3_hostname,
                               rejects_empty_filename,
                               rejects_negative_filesize,
                               rejects_invalid_size_type,
                               denies_slots_over_max_file_size
                              ]}].

suite() ->
    escalus:suite().

%%--------------------------------------------------------------------
%% Init & teardown
%%--------------------------------------------------------------------

init_per_suite(Config) ->
    escalus:init_per_suite(Config).

end_per_suite(Config) ->
    escalus:end_per_suite(Config).

init_per_group(unset_size, Config) ->
    dynamic_modules:start(<<"localhost">>, mod_http_upload,
                          [{max_file_size, undefined} | ?S3_OPTS]),
    escalus:create_users(Config, escalus:get_users([bob]));
init_per_group(_, Config) ->
    dynamic_modules:start(<<"localhost">>, mod_http_upload, ?S3_OPTS),
    escalus:create_users(Config, escalus:get_users([bob])).

end_per_group(_, Config) ->
    dynamic_modules:stop(<<"localhost">>, mod_http_upload),
    escalus:delete_users(Config, escalus:get_users([bob])).

init_per_testcase(CaseName, Config) ->
    escalus:init_per_testcase(CaseName, Config).

end_per_testcase(CaseName, Config) ->
    escalus:end_per_testcase(CaseName, Config).

%%--------------------------------------------------------------------
%% Service discovery test
%%--------------------------------------------------------------------

http_upload_item_discovery(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = escalus_client:server(Bob),
              Result = escalus:send_and_wait(Bob, escalus_stanza:disco_items(ServJID)),
              escalus:assert(is_iq_result, Result),
              escalus:assert(has_item, [upload_service(Bob)], Result)
      end).

http_upload_feature_discovery(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = escalus_client:server(Bob),
              Result = escalus:send_and_wait(Bob, escalus_stanza:disco_info(ServJID)),
              escalus:assert(fun has_no_feature/2, [?NS_HTTP_UPLOAD], Result),
              SubServJID = upload_service(Bob),
              SubResult = escalus:send_and_wait(Bob, escalus_stanza:disco_info(SubServJID)),
              escalus:assert(has_feature, [?NS_HTTP_UPLOAD], SubResult)
      end).

advertises_max_file_size(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Result = escalus:send_and_wait(Bob, escalus_stanza:disco_info(ServJID)),
              Form = exml_query:path(Result, [{element, <<"query">>}, {element, <<"x">>}]),
              escalus:assert(has_type, [<<"result">>], Form),
              escalus:assert(has_ns, [?NS_XDATA], Form),
              escalus:assert(fun has_field/4, [<<"max-file-size">>, undefined, <<"1234">>], Form),
              escalus:assert(fun has_field/4, [<<"FORM_TYPE">>, <<"hidden">>, ?NS_HTTP_UPLOAD],
                             Form)
      end).

does_not_advertise_max_size_if_unset(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Result = escalus:send_and_wait(Bob, escalus_stanza:disco_info(ServJID)),
              undefined = exml_query:path(Result, {element, <<"x">>})
      end).

rejects_set_iq(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              IQ = escalus_stanza:iq_set(?NS_HTTP_UPLOAD, []),
              Request = escalus_stanza:to(IQ, ServJID),
              Result = escalus:send_and_wait(Bob, Request),
              escalus_assert:is_error(Result, <<"cancel">>, <<"not-allowed">>)
      end).

request_slot(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Request = create_slot_request_stanza(ServJID, <<"filename.jpg">>, 123, undefined),
              Result = escalus:send_and_wait(Bob, Request),
              escalus:assert(is_iq_result, Result),
              escalus:assert(fun check_namespace/1, Result),
              escalus:assert(fun check_put_and_get_fields/1, Result)
      end).

get_url_ends_with_filename(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Filename = <<"filename.jpg">>,
              Request = create_slot_request_stanza(ServJID, Filename, 123, undefined),
              Result = escalus:send_and_wait(Bob, Request),
              escalus:assert(fun check_path_ends_with/3, [<<"get">>, Filename], Result)
      end).

urls_contain_s3_hostname(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Request = create_slot_request_stanza(ServJID, <<"filename.jpg">>, 123, undefined),
              Result = escalus:send_and_wait(Bob, Request),
              escalus:assert(fun check_url_contains/3, [<<"get">>, <<?S3_HOSTNAME>>], Result),
              escalus:assert(fun check_url_contains/3, [<<"put">>, <<?S3_HOSTNAME>>], Result)
      end).

rejects_empty_filename(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Request = create_slot_request_stanza(ServJID, <<>>, 123, undefined),
              Result = escalus:send_and_wait(Bob, Request),
              escalus_assert:is_error(Result, <<"modify">>, <<"bad-request">>)
      end).

rejects_negative_filesize(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Request = create_slot_request_stanza(ServJID, <<"filename.jpg">>, -1, undefined),
              Result = escalus:send_and_wait(Bob, Request),
              escalus_assert:is_error(Result, <<"modify">>, <<"bad-request">>)
      end).

rejects_invalid_size_type(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Request = create_slot_request_stanza(ServJID, <<"filename.jpg">>,
                                                   <<"filesize">>, undefined),
              Result = escalus:send_and_wait(Bob, Request),
              escalus_assert:is_error(Result, <<"modify">>, <<"bad-request">>)
      end).

denies_slots_over_max_file_size(Config) ->
    escalus:story(
      Config, [{bob, 1}],
      fun(Bob) ->
              ServJID = upload_service(Bob),
              Request = create_slot_request_stanza(ServJID, <<"filename.jpg">>, 54321, undefined),
              Result = escalus:send_and_wait(Bob, Request),
              escalus:assert(is_error, [<<"modify">>, <<"not-acceptable">>], Result),
              <<"1234">> = exml_query:path(Result, [{element, <<"error">>},
                                                    {element, <<"file-too-large">>},
                                                    {element, <<"max-file-size">>},
                                                    cdata])
      end).

%%--------------------------------------------------------------------
%% Test helpers
%%--------------------------------------------------------------------

create_slot_request_stanza(Server, Filename, Size, ContentType) when is_integer(Size) ->
    create_slot_request_stanza(Server, Filename, integer_to_binary(Size), ContentType);
create_slot_request_stanza(Server, Filename, BinSize, ContentType) ->
    ContentTypeEl =
        case ContentType of
            undefined -> [];
            _ -> [#xmlel{name = <<"content-type">>, children = [exml:escape_cdata(ContentType)]}]
        end,

    Request =
        #xmlel{
           name = <<"request">>,
           attrs = [{<<"xmlns">>, ?NS_HTTP_UPLOAD}],
           children =
               [
                #xmlel{name = <<"filename">>, children = [exml:escape_cdata(Filename)]},
                #xmlel{name = <<"size">>, children = [exml:escape_cdata(BinSize)]}
                | ContentTypeEl
               ]},

    #xmlel{
       name = <<"iq">>,
       attrs = [{<<"type">>, <<"get">>}, {<<"to">>, Server}],
       children = [Request]}.

check_namespace(#xmlel{name = <<"iq">>, children = [Slot]}) ->
    case Slot of
        #xmlel{name = <<"slot">>, attrs = [{<<"xmlns">>, ?NS_HTTP_UPLOAD}]} -> true;
        _ -> false
    end;
check_namespace(_) ->
    false.

has_no_feature(Feature, Stanza) ->
    not escalus_pred:has_feature(Feature, Stanza).

check_put_and_get_fields(#xmlel{name = <<"iq">>, children = [Slot]}) ->
    check_put_and_get_fields(Slot);
check_put_and_get_fields(#xmlel{name = <<"slot">>, children = PutGet}) ->
    Put = lists:keyfind(<<"put">>, 2, PutGet),
    Get = lists:keyfind(<<"get">>, 2, PutGet),
    check_put_and_get_fields(Put) andalso check_put_and_get_fields(Get);
check_put_and_get_fields(#xmlel{name = Name, children = [#xmlcdata{content = Content}]})
  when Name =:= <<"put">>; Name =:= <<"get">> ->
    is_binary(Content) andalso Content =/= <<>>;
check_put_and_get_fields(_) ->
    false.

check_path_ends_with(UrlType, Filename, Result) ->
    Url = exml_query:path(Result, [{element, <<"slot">>}, {element, UrlType}, cdata]),
    {ok, {_, _, _, _, PathList, _}} = http_uri:parse(binary_to_list(Url)),
    FilenameSize = byte_size(Filename),
    ReverseFilename = reverse(Filename),
    case reverse(PathList) of
        <<ReverseFilename:FilenameSize/binary, _/binary>> -> true;
        _ -> false
    end.

check_url_contains(UrlType, Filename, Result) ->
    Url = exml_query:path(Result, [{element, <<"slot">>}, {element, UrlType}, cdata]),
    binary:match(Url, Filename) =/= nomatch.

reverse(List) when is_list(List) ->
    list_to_binary(lists:reverse(List));
reverse(Binary) ->
    reverse(binary_to_list(Binary)).

upload_service(Client) ->
    <<"upload.", (escalus_client:server(Client))/binary>>.

has_field(Var, Type, Value, Form) ->
    Fields = Form#xmlel.children,
    VarFits = fun(I) -> Var =:= undefined orelse exml_query:attr(I, <<"var">>) =:= Var end,
    TypeFits = fun(I) -> Type =:= undefined orelse exml_query:attr(I, <<"type">>) =:= Type end,
    ValueFits =
        fun(I) ->
                Value =:= undefined orelse
                    Value =:= exml_query:path(I, [{element, <<"value">>}, cdata])
        end,
    lists:any(fun(Item) -> VarFits(Item) andalso TypeFits(Item) andalso ValueFits(Item) end,
              Fields).
