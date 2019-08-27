(************************************************
				EvaluationUtilities.wl
*************************************************
Description:
	Utilities for evaluating input arriving
		from Jupyter, and for simulating
		the Mathematica REPL
Symbols defined:
	Print,
	Throw,
	Catch,
	simulatedEvaluate
*************************************************)

(************************************
	Get[] guard
*************************************)

If[
	!TrueQ[WolframLanguageForJupyter`Private`$GotEvaluationUtilities],
	
	WolframLanguageForJupyter`Private`$GotEvaluationUtilities = True;

(************************************
	load required
		WolframLanguageForJupyter
		files
*************************************)

	Get[FileNameJoin[{DirectoryName[$InputFileName], "Initialization.wl"}]]; (* loopState, applyHook, $canUseFrontEnd *)

(************************************
	wrapper for interacting
		with the cloud
*************************************)

	(* Interact is a wrapper, open to the user, for asking that the result of the evaluation
		be displayed as an embedded cloud object  that can be interacted with *)
	(* set Interact to not evaluate its arguments *)
	SetAttributes[Interact, HoldAll];

(************************************
	private symbols
*************************************)

	(* begin the private context for WolframLanguageForJupyter *)
	Begin["`Private`"];

(************************************
	helper utilities for
		diagnosing and removing
		command wrappers
		(e.g., Interact[])
*************************************)

	(* check if expr is wrapped with Interact *)
	interactQ[expr___] := MatchQ[expr, Hold[Interact[___]]];
	SetAttributes[interactQ, HoldAll];

	(* remove any Interact wrappers,
		apply $Pre,
		and bring in the Front End for the evaluation of expr *)
	uninteract[Interact[expr_]] := UsingFrontEnd[applyHook[$Pre, expr]];
	uninteract[expr_] := UsingFrontEnd[applyHook[$Pre, expr]];
	SetAttributes[uninteract, HoldAll];

(************************************
	version of Print that
		sends output to Jupyter
*************************************)

	(* redirect Print calls into a message to Jupyter, in order to print in the Jupyter notebook *)
	(* TODO: review other methods: through EvaluationData or WSTP so we don't redefine Print *)
	Unprotect[Print];
	Print[args___, opts:OptionsPattern[]] :=
		Block[
			{
				$inPrint=True,
				$Output={OpenWrite[FormatType->OutputForm]}
			},
			If[
				!FailureQ[First[$Output]],
					Print[args, opts];
					loopState["printFunction"][
						Import[$Output[[1,1]], "String"]
					];
			];
			Close[First[$Output]];
			Null
		] /; !TrueQ[$inPrint];
	Protect[Print];

(************************************
	versions of Throw and
		Catch that we can
		more easily intercept
*************************************)

	Unprotect[Throw];
	Throw[value_] :=
		Throw[
			value,
			WolframLanguageForJupyter`Private`$ThrowLabel
		];
	Protect[Throw];

	Unprotect[Catch];
	Catch[expr_] :=
		Catch[
			expr,
			WolframLanguageForJupyter`Private`$ThrowLabel
		];
	Protect[Catch];

(************************************
	utilities for splitting
		input by Wolfram Language
		expression
*************************************)

	(* start parsing the input, and return an Association for keeping track of said parse *)
	startParsingInput[codeStr_] :=
		Module[
			{
				(* an Association for keeping track of the parse containing:
					"LinesLeft" - the lines of input left to be processed,
					"ExpressionsParsed" - the number of expressions parsed out so far,
					"ExpressionString" - an expression string generated by a pass of the parser,
					"SyntaxError" - a flag for if the expression string contains a syntax error,
					"ParseDone" - a flag for if the parse is done *)
				parseTrackerInit
			},

			(* initialize parseTrackerInit *)
			parseTrackerInit = Association[];

			(* add the annotated lines left, and the defaults *)
			AssociateTo[
				parseTrackerInit,
				{
					"LinesLeft" -> StringSplit[StringJoin[" ", codeStr], "\r\n" | "\n"],
					"ExpressionsParsed" -> 0,
					"ExpressionString" -> " ",
					"SyntaxError" -> False,
					"ParseDone" -> False
				}
			];

			(* return the parse tracker *)
			Return[parseTrackerInit];
		];

	(* parse out an expression *)
	parseIntoExpr[tracker_] :=
		Module[
			{
				(* the parse tracker to be updated with the results of this parse *)
				newTracker,

				(* for storing the lines of input left to be processed, annotated with their line numbers *)
				annotatedLinesLeft,

				(* for storing the current line position when moving through annotatedLinesLeft *)
				linePos,

				(* for storing the result *)
				result,

				(* for storing the concatenation of some lines of input *)
				exprStr
			},

			(* initialize the parse tracker to be updated *)
			newTracker = tracker;

			(* if there are no lines of input left to be processed,
				set newTracker["ParseDone"] to True and return the updated tracker *)
			If[Length[newTracker["LinesLeft"]] == 0,
				newTracker["ParseDone"] = True;
				(* return the updated tracker *)
				Return[newTracker];
			];

			(* annotate the lines of input left to be processed with their line numbers *)
			annotatedLinesLeft = 
				Partition[
					Riffle[
						newTracker["LinesLeft"],
						Range[Length[newTracker["LinesLeft"]]]
					],
					2
				];

			(* start with a line position of 1 *)
			linePos = 1;
			result =
				(* fold until an expression is built, or there are no lines of input left *)
				Fold[
					(
						(* save the new line position *)
						linePos = Last[{##}][[2]] + 1;
						(* save the new expression string with a new line of input *)
						exprStr = StringJoin[First /@ {##}];
						(* if exprStr is syntactically correct, it represents a complete expression,
							and folding can be stopped *)
						If[SyntaxQ[exprStr],
							(* return the complete expression string *)
							Return[{exprStr, linePos, False}, Fold];,
							(* exprStr may be incomplete, keep going if possible *)
							{exprStr, linePos, True}
						]
					) &,
					(* starting value *)
					{"", -1, False},
					(* the annotated lines of input left to be processed *)
					annotatedLinesLeft
				];

			AssociateTo[
				newTracker,
				{
					(* discard the lines of input processed *)
					"LinesLeft" -> newTracker["LinesLeft"][[result[[2]];;]],
					(* increment ExpressionsParsed *)
					"ExpressionsParsed" -> newTracker["ExpressionsParsed"] + 1,
					(* save the result generated *)
					"ExpressionString" -> result[[1]],
					(* save the syntactic correctness of the result *)
					"SyntaxError" -> result[[3]]
				}
			];

			(* return the updated tracker *)
			Return[newTracker];
		];

(************************************
	main evaluation command
*************************************)

	(* evaluate input, and capture required information such as generated messages *)
	(* TODO: review other method: evaluate input through WSTP in another kernel *)
	simulatedEvaluate[codeStr_] :=
		Module[
			{
				(* for saving $Messages before changing it *)
				oldMessages,
				(* the stream used to capture generated messages *)
				stream,
				(* the string form of the generated messages, obtained from stream *)
				generatedMessages,

				(* for keeping track of parsing the input into separate expressions *)
				parseTracker,

				(* a raw evaluation result to be built, before Nulls have been removed *)
				rawEvaluationResult,

				(* for storing a single expression string *)
				exprStr,

				(* the result of evaluation *)
				evaluationResult,

				(* for storing intermediate results *)
				intermediate,

				(* for storing final results *)
				result,

				(* the total result of the evaluation:
					an association containing
						the result of evaluation ("EvaluationResult"),
						indices of the output lines of the result ("EvaluationResultOutputLineIndices"),
						the total number of indices consumed by this evaluation ("ConsumedIndices"),
						generated messages ("GeneratedMessages"),
						if the input was one expression and wrapped with Interact[] ("InteractStatus")
				*)
				totalResult
			},

			(* create the association for the total result of the evaluation *)
			totalResult = Association[];

			(* save $Messages before overwrite *)
			oldMessages = $Messages;
			(* open stream to write messages into *)
			stream = OpenWrite[];

			(* clear the list of generated messages *)
			Unprotect[$MessageList]; $MessageList = {}; Protect[$MessageList];

			(* set $Messages to use the new stream *)
			$Messages = {stream};

			(* start the parse of the input *)
			parseTracker =
				startParsingInput[
					(* apply $PreRead to the input *)
					applyHook[$PreRead, codeStr]
				];

			(* initialize rawEvaluationResult to an empty list *)
			rawEvaluationResult = {};
			(* while the parse is not done, keep evaluating expressions in the input *)
			While[
				(
					parseTracker = parseIntoExpr[parseTracker];
					!parseTracker["ParseDone"]
				),

				(* save the current expression string *)
				exprStr = parseTracker["ExpressionString"];

				If[
					!parseTracker["SyntaxError"],
					(* increment $Line *)
					$Line++;
					(* set InString *)
					Unprotect[InString];
					InString[
							loopState["executionCount"] + parseTracker["ExpressionsParsed"] - 1
						] = exprStr;
					Protect[InString];
				];

				(* catch any Throws that were not handled by the input itself *)
				intermediate = 
					Catch[
						(* evaluate the expression string *)
						ToExpression[
							exprStr,
							InputForm,
							uninteract
						],
						_,
						WolframLanguageForJupyter`Private`$ThrowNoCatch[#1, #2] &
					];

				If[
					Head[intermediate] =!= WolframLanguageForJupyter`Private`$ThrowNoCatch,
					(* if we did not catch anything, set result to intermediate *)
					result = intermediate;,
					(* if we did catch something, obtain the correct held form of the Throw to return, and message *)
					If[intermediate[[2]] === WolframLanguageForJupyter`Private`$ThrowLabel,
						result = Replace[Hold[Throw[placeHolder]], {placeHolder -> intermediate[[1]]}, {2}];,
						result = Replace[Hold[Throw[placeHolder1, placeHolder2]], {placeHolder1 -> intermediate[[1]], placeHolder2 -> intermediate[[2]]}, {2}];
					];
					(* message *)
					Message[
						Throw::nocatch,
						StringTrim[ToString[result, OutputForm], "Hold[" | "]"]
					];
				];

				If[
					!parseTracker["SyntaxError"],
					(* set the In[] for this expression *)
					Unprotect[In];
					Replace[
						ToExpression[exprStr, InputForm, Hold],
						Hold[held_] :> 
							SetDelayed[
								In[
									loopState["executionCount"] + parseTracker["ExpressionsParsed"] - 1
								],
								held
							]
					];
					Protect[In];
					(* apply $Post to the result *)
					result = applyHook[$Post, result];
					(* set the Out[] for this expression *)
					Unprotect[Out];
					Out[loopState["executionCount"] + parseTracker["ExpressionsParsed"] - 1] = result;
					Protect[Out];
					(* create the overall result with $PrePrint *)
					result = applyHook[$PrePrint, result];
					,
					(* syntax error *)
					result = $Failed;
				];

				(* save the result in rawEvaluationResult *)
				AppendTo[rawEvaluationResult, result];
			];

			(* add the Interact[] wrapper status of the input *)
			AssociateTo[
				totalResult,
				"InteractStatus" ->
					(
						(* if the input has no syntax errors,
							is made up of only one expression,
							and is wrapped with Interact[],
							mark "InteractStatus" as True
							*)
						parseTracker["ExpressionsParsed"] == 1 &&
							!parseTracker["SyntaxError"] &&
								(interactQ @ ToExpression[parseTracker["ExpressionString"], InputForm, Hold])
					)
			];

			(* evaluate the input from Jupyter, removing Nulls from the Output *)
			evaluationResult = DeleteCases[rawEvaluationResult, Null];

			(* preserve the locations of the output lines with respect to the Nulls *)
			AssociateTo[
				totalResult,
				"EvaluationResultOutputLineIndices" -> 
					(
						(loopState["executionCount"] - 1) + 
							Flatten[Position[rawEvaluationResult, Except[Null], {1}, Heads -> False]]
					)
			];

			(* restore $Messages *)
			$Messages = oldMessages;

			(* obtain generated messages *)
			generatedMessages = Import[stream[[1]], "String"];
			(* close the opened stream *)
			Close[stream];

			(* add the total number of indices consumed by this evaluation *)
			AssociateTo[
				totalResult,
				"ConsumedIndices" -> 
					(* if parseTracker["SyntaxError"] is true, one less index was consumed *)
					If[
						parseTracker["SyntaxError"],
						parseTracker["ExpressionsParsed"] - 1,
						parseTracker["ExpressionsParsed"]
					]
			];

			(* add the result of the evaluation and any generated messages to totalResult *)
			AssociateTo[totalResult, {"EvaluationResult" -> evaluationResult, "GeneratedMessages" -> generatedMessages}];

			(* return totalResult *)
			Return[totalResult];
		];
	(* set simulatedEvaluate to not implicitly evaluate its arguments *)
	SetAttributes[simulatedEvaluate, HoldAll];

	(* end the private context for WolframLanguageForJupyter *)
	End[]; (* `Private` *)

(************************************
	Get[] guard
*************************************)

] (* WolframLanguageForJupyter`Private`$GotEvaluationUtilities *)