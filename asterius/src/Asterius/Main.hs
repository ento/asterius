{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}

module Asterius.Main
  ( Target (..),
    Task (..),
    getTask,
    ahcDistMain,
    ahcLinkMain,
  )
where

import qualified Asterius.Backends.Binaryen as Binaryen
import qualified Asterius.Backends.WasmToolkit as WasmToolkit
import Asterius.BuildInfo
import Asterius.Internals
import Asterius.Internals.ByteString
import Asterius.Internals.Temp
import Asterius.JSFFI
import Asterius.JSGen.Wasm
import Asterius.Ld (rtsUsedSymbols)
import Asterius.Main.Task
import Asterius.Resolve
import Asterius.Types
  ( AsteriusEntitySymbol (..),
    FFIExportDecl (..),
    FFIMarshalState (..),
    Module,
  )
import Control.Monad
import Control.Monad.Except
import Data.Binary.Get
import Data.Binary.Put
import qualified Data.ByteString as BS
import Data.ByteString.Builder
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Unsafe as BS
import Data.Foldable
import Data.List
import qualified Data.Map.Strict as M
import Data.Maybe
import qualified Data.Set as S
import Data.String
import Foreign
import Language.WebAssembly.WireFormat
import qualified Language.WebAssembly.WireFormat as Wasm
import NPM.Parcel
import System.Console.GetOpt
import System.Directory
import System.Environment.Blank
import System.FilePath
import System.IO hiding (IO)
import System.Process
import Prelude hiding (IO)

parseTask :: [String] -> Task
parseTask args = case err_msgs of
  [] -> task
  _ -> error $ show err_msgs
  where
    bool_opt s f = Option [] [s] (NoArg f) ""
    str_opt s f = Option [] [s] (ReqArg f "") ""
    (task_trans_list, _, err_msgs) =
      getOpt
        Permute
        [ bool_opt "browser" $ \t -> t {target = Browser},
          str_opt "input-hs" $ \s t ->
            t
              { inputHS = s,
                outputDirectory = takeDirectory s,
                outputBaseName = takeBaseName s
              },
          str_opt "input-exe" $ \s t ->
            t
              { inputHS = s,
                outputDirectory = takeDirectory s,
                outputBaseName = takeBaseName s
              },
          str_opt "input-mjs" $ \s t -> t {inputEntryMJS = Just s},
          str_opt "output-directory" $ \s t -> t {outputDirectory = s},
          str_opt "output-prefix" $ \s t -> t {outputBaseName = s},
          bool_opt "tail-calls" $ \t -> t {tailCalls = True},
          bool_opt "no-gc-sections" $ \t -> t {gcSections = False},
          bool_opt "bundle" $ \t -> t {bundle = True},
          str_opt "backend" $ \s t -> case s of
            "wasm-toolkit" -> t {backend = WasmToolkit}
            "binaryen" -> t {backend = Binaryen}
            _ -> error $ "Unsupported backend " <> show s,
          str_opt "optimize-level" $ \s t ->
            let i = read s
             in if i >= 0 && i <= 4
                  then t {optimizeLevel = i}
                  else error "Optimize level must be [0..4]",
          str_opt "shrink-level" $ \s t ->
            let i = read s
             in if i >= 0 && i <= 2
                  then t {shrinkLevel = i}
                  else error "Shrink level must be [0..2]",
          bool_opt "debug" $
            \t ->
              t
                { backend = Binaryen,
                  debug = True,
                  outputIR = True,
                  verboseErr = True
                },
          bool_opt "output-ir" $ \t -> t {outputIR = True},
          bool_opt "run" $ \t -> t {run = True},
          bool_opt "verbose-err" $ \t -> t {backend = Binaryen, verboseErr = True},
          bool_opt "yolo" $ \t -> t {yolo = True},
          str_opt "ghc-option" $
            \s t -> t {extraGHCFlags = extraGHCFlags t <> [s]},
          str_opt "export-function" $
            \s t -> t {exportFunctions = fromString s : exportFunctions t},
          str_opt "extra-root-symbol" $
            \s t -> t {extraRootSymbols = fromString s : extraRootSymbols t},
          str_opt "gc-threshold" $ \s t -> t {gcThreshold = read s}
        ]
        args
    task = foldl' (flip ($)) defTask task_trans_list

getTask :: IO Task
getTask = parseTask <$> getArgs

genPackageJSON :: Task -> Builder
genPackageJSON task =
  mconcat
    [ "{\"name\": \"",
      base_name,
      "\",\n",
      "\"version\": \"0.0.1\",\n",
      "\"browserslist\": [\"last 1 Chrome version\"]\n",
      "}\n"
    ]
  where
    base_name = string7 (outputBaseName task)

genSymbolDict :: M.Map AsteriusEntitySymbol Int64 -> Builder
genSymbolDict sym_map =
  "Object.freeze({"
    <> mconcat
      ( intersperse
          ","
          [ "\"" <> shortByteString (entityName sym) <> "\":" <> intHex sym_idx
            | (sym, sym_idx) <- M.toList sym_map
          ]
      )
    <> "})"

genInfoTables :: [Int64] -> Builder
genInfoTables sym_set =
  "new Set([" <> mconcat (intersperse "," (map intHex sym_set)) <> "])"

genExportStablePtrs ::
  M.Map AsteriusEntitySymbol Int64 ->
  [AsteriusEntitySymbol] ->
  FFIMarshalState ->
  Builder
genExportStablePtrs sym_map export_funcs FFIMarshalState {..} =
  "["
    <> mconcat
      ( intersperse
          ","
          ( map
              (intHex . (sym_map !) . ffiExportClosure . (ffiExportDecls !))
              export_funcs
          )
      )
    <> "]"

genReq :: Task -> LinkReport -> Builder
genReq task LinkReport {..} =
  mconcat
    [ "export default (async () => {return {",
      "jsffiFactory: ",
      generateFFIImportObjectFactory bundledFFIMarshalState,
      ", exports: ",
      generateFFIExportObject bundledFFIMarshalState,
      ", symbolTable: ",
      genSymbolDict symbol_table,
      if debug task
        then mconcat [", infoTables: ", genInfoTables infoTableSet]
        else mempty,
      ", exportStablePtrs: ",
      genExportStablePtrs
        staticsSymbolMap
        (exportFunctions task)
        bundledFFIMarshalState,
      ", tableSlots: ",
      intDec tableSlots,
      ", staticMBlocks: ",
      intDec staticMBlocks,
      ", yolo: ",
      if yolo task then "true" else "false",
      ", gcThreshold: ",
      intHex (gcThreshold task),
      -- target-specific import
      ", targetSpecific: await import('./",
      (case target task of
          Node -> "node"
          Browser -> "browser"),
      "/specific.mjs')",
      "}})()",
      ";\n"
    ]
  where
    raw_symbol_table = staticsSymbolMap <> functionSymbolMap
    symbol_table =
      M.restrictKeys raw_symbol_table $
        S.fromList
          [ ffiExportClosure
            | FFIExportDecl {..} <-
                M.elems $
                  ffiExportDecls bundledFFIMarshalState
          ]
          <> S.fromList (extraRootSymbols task)
          <> rtsUsedSymbols

genDefEntry :: Task -> Builder
genDefEntry task =
  mconcat
    [ "import * as rts from \"./rts.mjs\";\n",
      "import module from \"./",
      out_base,
      ".wasm.mjs\";\n",
      "import reqPromise from \"./",
      out_base,
      ".req.mjs\";\n",
      case target task of
        Node -> "process.on(\"unhandledRejection\", err => { throw err; });\n"
        Browser -> mempty,
      mconcat
        [ "reqPromise.then(req => module.then(m => rts.newAsteriusInstance(Object.assign(req, {module: m}))).then(async i => {\n",
          "try {\n",
          "i.exports.hs_init();\n",
          "await i.exports.main();\n",
          "} catch (err) {\n",
          "console.log(i.stdio.stdout());\n",
          "console.log(i.stdio.stderr());\n",
          "throw err;\n",
          "}\n",
          "if (i.stdio.stdout().toString().length) console.log(i.stdio.stdout());\n",
          "if (i.stdio.stderr().toString().length) console.log(i.stdio.stderr());\n",
          "}));\n"
        ]
    ]
  where
    out_base = string7 (outputBaseName task)

genHTML :: Task -> Builder
genHTML task =
  mconcat
    [ "<!doctype html>\n",
      "<html lang=\"en\">\n",
      "<head>\n",
      "<title>",
      out_base,
      "</title>\n",
      "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=UTF-8\">\n",
      "</head>\n",
      "<body>\n",
      if bundle task
        then "<script src=\"" <> out_js <> "\"></script>\n"
        else "<script type=\"module\" src=\"" <> out_entry <> "\"></script>\n",
      "</body>\n",
      "</html>\n"
    ]
  where
    out_base = string7 (outputBaseName task)
    out_entry = string7 $ outputBaseName task <.> "mjs"
    out_js = string7 $ outputBaseName task <.> "js"

builderWriteFile :: FilePath -> Builder -> IO ()
builderWriteFile p b = withBinaryFile p WriteMode $ \h -> hPutBuilder h b

ahcLink :: Task -> IO (Asterius.Types.Module, LinkReport)
ahcLink task = do
  ld_output <- temp (takeBaseName (inputHS task))
  putStrLn $ "[INFO] Compiling " <> inputHS task <> " to WebAssembly"
  callProcess ahc $
    [ "--make",
      "-O",
      "-i" <> takeDirectory (inputHS task),
      "-fexternal-interpreter",
      "-pgml" <> ahcLd,
      "-clear-package-db",
      "-global-package-db"
    ]
      <> ["-optl--debug" | debug task]
      <> [ "-optl--extra-root-symbol=" <> c8SBS (entityName root_sym)
           | root_sym <- extraRootSymbols task
         ]
      <> [ "-optl--export-function=" <> c8SBS (entityName export_func)
           | export_func <- exportFunctions task
         ]
      <> ["-optl--no-gc-sections" | not (gcSections task)]
      <> ["-optl--verbose-err" | verboseErr task]
      <> extraGHCFlags task
      <> [ "-optl--output-ir="
             <> outputDirectory task
             </> (outputBaseName task <.> "unlinked.bin")
           | outputIR task
         ]
      <> ["-optl--prog-name=" <> takeBaseName (inputHS task)]
      <> ["-o", ld_output, inputHS task]
  r <- decodeFile ld_output
  removeFile ld_output
  pure r

ahcDistMain ::
  (String -> IO ()) -> Task -> (Asterius.Types.Module, LinkReport) -> IO ()
ahcDistMain logger task (final_m, report) = do
  let out_package_json = outputDirectory task </> "package.json"
      out_wasm = outputDirectory task </> outputBaseName task <.> "wasm"
      out_wasm_lib = outputDirectory task </> outputBaseName task <.> "wasm.mjs"
      out_req = outputDirectory task </> outputBaseName task <.> "req.mjs"
      out_entry = outputDirectory task </> outputBaseName task <.> "mjs"
      out_js = outputDirectory task </> outputBaseName task <.> "js"
      out_html = outputDirectory task </> outputBaseName task <.> "html"
      out_link = outputDirectory task </> outputBaseName task <.> "link.txt"
  when (outputIR task) $ do
    logger $ "[INFO] Writing linking report to " <> show out_link
    writeFile out_link $ show report
  when (outputIR task) $ do
    let p = out_wasm -<.> "linked.txt"
    logger $ "[INFO] Printing linked IR to " <> show p
    writeFile p $ show final_m
  case backend task of
    Binaryen -> do
      logger "[INFO] Converting linked IR to binaryen IR"
      Binaryen.c_BinaryenSetDebugInfo $ if verboseErr task then 1 else 0
      Binaryen.c_BinaryenSetOptimizeLevel $ fromIntegral $ optimizeLevel task
      Binaryen.c_BinaryenSetShrinkLevel $ fromIntegral $ shrinkLevel task
      m_ref <-
        Binaryen.marshalModule
          (staticsSymbolMap report <> functionSymbolMap report)
          final_m
      when (optimizeLevel task > 0 || shrinkLevel task > 0) $ do
        logger "[INFO] Running binaryen optimization"
        Binaryen.c_BinaryenModuleOptimize m_ref
      logger "[INFO] Validating binaryen IR"
      pass_validation <- Binaryen.c_BinaryenModuleValidate m_ref
      when (pass_validation /= 1) $ fail "[ERROR] binaryen validation failed"
      m_bin <- Binaryen.serializeModule m_ref
      logger $ "[INFO] Writing WebAssembly binary to " <> show out_wasm
      BS.writeFile out_wasm m_bin
      when (outputIR task) $ do
        let p = out_wasm -<.> "binaryen-show.txt"
        logger $ "[info] writing re-parsed wasm-toolkit ir to " <> show p
        case runGetOrFail Wasm.getModule (LBS.fromStrict m_bin) of
          Right (rest, _, r)
            | LBS.null rest -> writeFile p (show r)
            | otherwise -> fail "[ERROR] Re-parsing produced residule"
          _ -> fail "[ERROR] Re-parsing failed"
        let out_wasm_binaryen_sexpr = out_wasm -<.> "binaryen-sexpr.txt"
        logger $
          "[info] writing re-parsed wasm-toolkit ir as s-expresions to "
            <> show out_wasm_binaryen_sexpr
        -- disable colors when writing out the binaryen module
        -- to a file, so that we don't get ANSI escape sequences
        -- for colors. Reset the state after
        cenabled <- Binaryen.isColorsEnabled
        Binaryen.setColorsEnabled False
        m_sexpr <- Binaryen.serializeModuleSExpr m_ref
        Binaryen.setColorsEnabled cenabled
        BS.writeFile out_wasm_binaryen_sexpr m_sexpr
      Binaryen.c_BinaryenModuleDispose m_ref
    WasmToolkit -> do
      logger "[INFO] Converting linked IR to wasm-toolkit IR"
      let conv_result =
            runExcept $
              WasmToolkit.makeModule
                (tailCalls task)
                (staticsSymbolMap report <> functionSymbolMap report)
                final_m
      r <- case conv_result of
        Left err -> fail $ "[ERROR] Conversion failed with " <> show err
        Right r -> pure r
      when (outputIR task) $ do
        let p = out_wasm -<.> "wasm-toolkit.txt"
        logger $ "[INFO] Writing wasm-toolkit IR to " <> show p
        writeFile p $ show r
      fin <-
        if optimizeLevel task > 0 || shrinkLevel task > 0
          then do
            logger "[INFO] Re-parsing wasm-toolkit IR with binaryen"
            m_ref <-
              BS.unsafeUseAsCStringLen
                (LBS.toStrict $ toLazyByteString $ execPut $ putModule r)
                $ \(p, l) -> Binaryen.c_BinaryenModuleRead p (fromIntegral l)
            logger "[INFO] Running binaryen optimization"
            Binaryen.c_BinaryenModuleOptimize m_ref
            b <- Binaryen.serializeModule m_ref
            Binaryen.c_BinaryenModuleDispose m_ref
            pure $ Left b
          else pure $ Right $ execPut $ putModule r
      logger $ "[INFO] Writing WebAssembly binary to " <> show out_wasm
      case fin of
        Left b -> BS.writeFile out_wasm b
        Right b -> withBinaryFile out_wasm WriteMode $ \h -> hPutBuilder h b
  logger $
    "[INFO] Writing JavaScript runtime modules to "
      <> show
        (outputDirectory task)
  rts_files' <- listDirectory $ dataDir </> "rts"
  let rts_files = filter (\x -> x /= "browser" && x /= "node") rts_files'
  for_ rts_files $
    \f -> copyFile (dataDir </> "rts" </> f) (outputDirectory task </> f)
  let specificFolder =
        case target task of
          Node -> "node"
          Browser -> "browser"
  createDirectoryIfMissing False (outputDirectory task </> specificFolder)
  copyFile (dataDir </> "rts" </> specificFolder </> "specific.mjs") (outputDirectory task </> specificFolder </> "specific.mjs")
  logger $ "[INFO] Writing JavaScript loader module to " <> show out_wasm_lib
  builderWriteFile out_wasm_lib $
    genWasm (target task == Node) (outputBaseName task)
  logger $ "[INFO] Writing JavaScript req module to " <> show out_req
  builderWriteFile out_req $ genReq task report
  logger $ "[INFO] Writing JavaScript entry module to " <> show out_entry
  case inputEntryMJS task of
    Just in_entry -> copyFile in_entry out_entry
    _ -> builderWriteFile out_entry $ genDefEntry task
  when (bundle task) $ do
    package_json_exist <- doesFileExist out_package_json
    unless package_json_exist $ do
      logger $ "[INFO] Writing a stub package.json to " <> show out_package_json
      builderWriteFile out_package_json $ genPackageJSON task
    logger $ "[INFO] Writing JavaScript bundled script to " <> show out_js
    withCurrentDirectory (outputDirectory task) $
      callProcess
        "node"
        [ parcel,
          "build",
          "--out-dir",
          ".",
          "--out-file",
          takeFileName out_js,
          "--no-cache",
          "--no-source-maps",
          "--no-autoinstall",
          "--no-content-hash",
          "--target",
          case target task of
            Node -> "node"
            Browser -> "browser",
          takeFileName out_entry
        ]
  when (target task == Browser) $ do
    logger $ "[INFO] Writing HTML to " <> show out_html
    builderWriteFile out_html $ genHTML task
  when (target task == Node && run task)
    $ withCurrentDirectory (takeDirectory out_wasm)
    $ if bundle task
      then do
        logger $ "[INFO] Running " <> out_js
        callProcess "node" $
          ["--experimental-wasm-bigint" | debug task]
            <> ["--experimental-wasm-return-call" | tailCalls task]
            <> [takeFileName out_js]
      else do
        logger $ "[INFO] Running " <> out_entry
        callProcess "node" $
          ["--experimental-wasm-bigint" | debug task]
            <> ["--experimental-wasm-return-call" | tailCalls task]
            <> ["--experimental-modules", takeFileName out_entry]

ahcLinkMain :: Task -> IO ()
ahcLinkMain task = do
  ld_result <- ahcLink task
  ahcDistMain putStrLn task ld_result
