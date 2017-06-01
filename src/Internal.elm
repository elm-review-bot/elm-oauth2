module Internal exposing (..)

import OAuth exposing (..)
import Http as Http
import QueryString as QS
import Navigation as Navigation
import Json.Decode as Json
import Base64


authorize : Authorization -> Cmd msg
authorize { clientId, url, redirectUri, responseType, scope, state } =
    let
        qs =
            QS.empty
                |> QS.add "client_id" clientId
                |> QS.add "redirect_uri" redirectUri
                |> QS.add "response_type" (showResponseType responseType)
                |> qsAddList "scope" scope
                |> qsAddMaybe "state" state
                |> QS.render
    in
        Navigation.load (url ++ qs)


authenticate : Authentication -> Http.Request Response
authenticate authentication =
    case authentication of
        AuthorizationCode { clientId, code, url, redirectUri, scope, secret, state } ->
            let
                body =
                    QS.empty
                        |> QS.add "grant_type" "authorization_code"
                        |> QS.add "client_id" clientId
                        |> QS.add "redirect_uri" redirectUri
                        |> QS.add "code" code
                        |> qsAddList "scope" scope
                        |> qsAddMaybe "state" state
                        |> QS.render
                        |> String.dropLeft 1

                headers =
                    secret
                        |> Maybe.map (\s -> { clientId = clientId, secret = s })
                        |> authHeader
            in
                makeRequest url headers body

        ClientCredentials { clientId, url, scope, secret, state } ->
            let
                body =
                    QS.empty
                        |> QS.add "grant_type" "client_credentials"
                        |> qsAddList "scope" scope
                        |> qsAddMaybe "state" state
                        |> QS.render
                        |> String.dropLeft 1

                headers =
                    authHeader (Just { clientId = clientId, secret = secret })
            in
                makeRequest url headers body

        Password { credentials, url, password, scope, state, username } ->
            let
                body =
                    QS.empty
                        |> QS.add "username" username
                        |> QS.add "password" password
                        |> QS.add "grant_type" "password"
                        |> qsAddList "scope" scope
                        |> qsAddMaybe "state" state
                        |> QS.render
                        |> String.dropLeft 1

                headers =
                    authHeader credentials
            in
                makeRequest url headers body


makeRequest : String -> List Http.Header -> String -> Http.Request Response
makeRequest url headers body =
    Http.request
        { method = "POST"
        , headers = headers
        , url = url
        , body = Http.stringBody "application/x-www-form-urlencoded" body
        , expect = Http.expectJson decoder
        , timeout = Nothing
        , withCredentials = False
        }


authHeader : Maybe Credentials -> List Http.Header
authHeader credentials =
    credentials
        |> Maybe.map (\{ clientId, secret } -> Base64.encode (clientId ++ ":" ++ secret))
        |> Maybe.andThen Result.toMaybe
        |> Maybe.map (\s -> [ Http.header "Authorization" ("Basic " ++ s) ])
        |> Maybe.withDefault []


decoder : Json.Decoder Response
decoder =
    Json.oneOf
        [ Json.map5
            (\token expiresIn refreshToken scope state ->
                OkToken
                    { token = token
                    , expiresIn = expiresIn
                    , refreshToken = refreshToken
                    , scope = Maybe.withDefault [] scope
                    , state = state
                    }
            )
            accessTokenDecoder
            (Json.maybe <| Json.field "expires_in" Json.int)
            refreshTokenDecoder
            (Json.maybe <| Json.field "scope" (Json.list Json.string))
            (Json.maybe <| Json.field "state" Json.string)
        ]


accessTokenDecoder : Json.Decoder Token
accessTokenDecoder =
    let
        mtoken =
            Json.map2 makeToken
                (Json.field "access_token" Json.string |> Json.map Just)
                (Json.field "token_type" Json.string)

        failUnless =
            Maybe.map Json.succeed >> Maybe.withDefault (Json.fail "can't decode token")
    in
        Json.andThen failUnless mtoken


refreshTokenDecoder : Json.Decoder (Maybe Token)
refreshTokenDecoder =
    Json.map2 makeToken
        (Json.maybe <| Json.field "refresh_token" Json.string)
        (Json.field "token_type" Json.string)


makeToken : Maybe String -> String -> Maybe Token
makeToken mtoken tokenType =
    case ( mtoken, tokenType ) of
        ( Just token, "bearer" ) ->
            Just <| Bearer token

        _ ->
            Nothing


parseError : String -> Maybe String -> Maybe String -> Maybe String -> Result ParseError Response
parseError error mErrorDescription mErrorUri state =
    case ( mErrorDescription, mErrorUri ) of
        ( Just errorDescription, Just errorUri ) ->
            Ok <|
                OAuth.Err
                    { error = errorFromString error
                    , errorDescription = errorDescription
                    , errorUri = errorUri
                    , state = state
                    }

        ( Nothing, Just _ ) ->
            Result.Err <| Missing [ "error_description" ]

        ( Just _, Nothing ) ->
            Result.Err <| Missing [ "error_uri" ]

        ( Nothing, Nothing ) ->
            Result.Err <| Missing [ "error_description, error_uri" ]


parseToken : String -> Maybe String -> Maybe Int -> List String -> Maybe String -> Result ParseError Response
parseToken accessToken mTokenType mExpiresIn scope state =
    case ( mTokenType, mExpiresIn ) of
        ( Just "bearer", mExpiresIn ) ->
            Ok <|
                OkToken
                    { expiresIn = mExpiresIn
                    , refreshToken = Nothing
                    , scope = scope
                    , state = state
                    , token = Bearer accessToken
                    }

        ( Just _, _ ) ->
            Result.Err <| Invalid [ "token_type" ]

        ( Nothing, _ ) ->
            Result.Err <| Missing [ "token_type" ]


parseAuthorizationCode : String -> Maybe String -> Result ParseError Response
parseAuthorizationCode code state =
    Ok <|
        OkCode
            { code = code
            , state = state
            }


qsAddList : String -> List String -> QS.QueryString -> QS.QueryString
qsAddList param xs qs =
    case xs of
        [] ->
            qs

        h :: q ->
            qsAddList param q <| QS.add param h qs


qsAddMaybe : String -> Maybe String -> QS.QueryString -> QS.QueryString
qsAddMaybe param ms qs =
    case ms of
        Nothing ->
            qs

        Just s ->
            QS.add param s qs
