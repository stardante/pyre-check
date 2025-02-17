(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

val compute_dependencies
  :  state:State.t ->
  configuration:Configuration.Analysis.t ->
  removed_modules:Ast.Reference.t list ->
  Ast.SourcePath.t list ->
  Ast.Reference.Set.t
