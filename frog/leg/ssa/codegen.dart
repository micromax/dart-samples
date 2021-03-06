// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

class SsaCodeGeneratorTask extends CompilerTask {
  SsaCodeGeneratorTask(Compiler compiler) : super(compiler);
  String get name() => 'SSA code generator';

  String generate(WorkItem work, HGraph graph) {
    return measure(() {
      FunctionElement function = work.element;
      Map<Element, String> parameterNames =
          new LinkedHashMap<Element, String>();

      function.computeParameters(compiler).forEachParameter((Element element) {
        parameterNames[element] =
            JsNames.getValid('${element.name.slowToString()}');
      });

      String code = generateMethod(parameterNames, work, graph);
      return code;
    });
  }

  void preGenerateMethod(HGraph graph, WorkItem work) {
    compiler.tracer.traceGraph("codegen", graph);
    new SsaInstructionMerger().visitGraph(graph);
    // Replace the results of check instructions with the
    // original value, if the result is used. This is safe now,
    // since we don't do code motion after this point.
    new SsaCheckInstructionUnuser().visitGraph(graph);
    new SsaConditionMerger().visitGraph(graph);
    new SsaPhiEliminator(work).visitGraph(graph);
    compiler.tracer.traceGraph("no-phi", graph);
  }

  String generateMethod(Map<Element, String> parameterNames,
                        WorkItem work,
                        HGraph graph) {
    preGenerateMethod(graph, work);
    StringBuffer buffer = new StringBuffer();
    StringBuffer parameters = new StringBuffer();
    List<String> names = parameterNames.getValues();
    for (int i = 0; i < names.length; i++) {
      if (i != 0) parameters.add(', ');
      parameters.add(names[i]);
    }

    if (work.isBailoutVersion()) {
      new SsaBailoutPropagator(compiler).visitGraph(graph);
      SsaUnoptimizedCodeGenerator codegen = new SsaUnoptimizedCodeGenerator(
          compiler, work, buffer, parameters, parameterNames);
      codegen.visitGraph(graph);
      StringBuffer newParameters = new StringBuffer();
      if (!parameterNames.isEmpty()) newParameters.add('$parameters, ');
      newParameters.add('state');
      for (int i = 0; i < codegen.maxBailoutParameters; i++) {
        newParameters.add(', env$i');
      }
      return 'function($newParameters) {\n${codegen.setup}$buffer}';
    } else {
      SsaOptimizedCodeGenerator codegen = new SsaOptimizedCodeGenerator(
          compiler, work, buffer, parameters, parameterNames);
      codegen.visitGraph(graph);
      if (!codegen.guards.isEmpty()) {
        addBailoutVersion(codegen.guards, work);
      }
      return 'function($parameters) {\n$buffer}';
    }
  }

  void addBailoutVersion(List<HTypeGuard> guards, WorkItem work) {
    int length = guards.length;
    Map<int, BailoutInfo> bailouts = new Map<int, BailoutInfo>();
    int bailoutId = 1;
    guards.forEach((HTypeGuard guard) {
      if (guard.guarded is !HParameterValue) {
        int originalGuardedId = guard.originalGuardedId;
        BailoutInfo info = new BailoutInfo(originalGuardedId, bailoutId++);
        bailouts[originalGuardedId] = info;
      }
    });
    compiler.enqueue(new WorkItem.bailoutVersion(
        work.element, work.resolutionTree, bailouts));
  }
}

class SsaCodeGenerator implements HVisitor {
  final Compiler compiler;
  final WorkItem work;
  final StringBuffer buffer;
  final StringBuffer parameters;

  final Map<Element, String> parameterNames;
  final Map<int, String> names;
  final Map<String, int> prefixes;

  Element equalsNullElement;
  int indent = 0;
  int expectedPrecedence = JSPrecedence.STATEMENT_PRECEDENCE;
  HGraph currentGraph;
  HBasicBlock currentBlock;

  SubGraph subGraph;

  SsaCodeGenerator(this.compiler,
                   this.work,
                   this.buffer,
                   this.parameters,
                   this.parameterNames)
    : names = new Map<int, String>(),
      prefixes = new Map<String, int>() {
    for (final name in parameterNames.getValues()) {
      prefixes[name] = 0;
    }
    equalsNullElement =
        compiler.builder.interceptors.getEqualsNullInterceptor();
  }

  abstract visitTypeGuard(HTypeGuard node);
  abstract visitBailoutTarget(HBailoutTarget node);

  abstract beginGraph(HGraph graph);
  abstract endGraph(HGraph graph);

  abstract beginLoop(HBasicBlock block);
  abstract endLoop(HBasicBlock block);
  abstract handleLoopCondition(HLoopBranch node);

  abstract startIf(HIf node);
  abstract endIf(HIf node);
  abstract startThen(HIf node);
  abstract endThen(HIf node);
  abstract startElse(HIf node);
  abstract endElse(HIf node);

  void beginExpression(int precedence) {
    if (precedence < expectedPrecedence) {
      buffer.add('(');
    }
  }
  void endExpression(int precedence) {
    if (precedence < expectedPrecedence) {
      buffer.add(')');
    }
  }

  visitGraph(HGraph graph) {
    currentGraph = graph;
    indent++;  // We are already inside a function.
    subGraph = new SubGraph(graph.entry, graph.exit);
    beginGraph(graph);
    visitBasicBlock(graph.entry);
    endGraph(graph);
  }

  void visitSubGraph(SubGraph newSubGraph) {
    SubGraph oldSubGraph = subGraph;
    subGraph = newSubGraph;
    visitBasicBlock(subGraph.start);
    subGraph = oldSubGraph;
  }

  String temporary(HInstruction instruction) {
    int id = instruction.id;
    String name = names[id];
    if (name !== null) return name;

    String prefix = 't';
    if (!prefixes.containsKey(prefix)) prefixes[prefix] = 0;
    return newName(id, '${prefix}${prefixes[prefix]++}');
  }

  String local(HLocal local) {
    Element element = local.element;
    if (element != null && element.kind == ElementKind.PARAMETER) {
      return parameterNames[element];
    }
    int id = local.id;
    String name = names[id];
    if (name !== null) return name;

    String prefix;
    if (element !== null) {
      prefix = element.name.slowToString();
    } else {
      prefix = 'v';
    }
    if (!prefixes.containsKey(prefix)) {
      prefixes[prefix] = 0;
      return newName(id, prefix);
    } else {
      return newName(id, '${prefix}_${prefixes[prefix]++}');
    }
  }

  String newName(int id, String name) {
    String result = JsNames.getValid(name);
    names[id] = result;
    return result;
  }

  /**
    * Only visits the arguments starting at inputs[HInvoke.ARGUMENTS_OFFSET].
    */
  void visitArguments(List<HInstruction> inputs) {
    assert(inputs.length >= HInvoke.ARGUMENTS_OFFSET);
    buffer.add('(');
    for (int i = HInvoke.ARGUMENTS_OFFSET; i < inputs.length; i++) {
      if (i != HInvoke.ARGUMENTS_OFFSET) buffer.add(', ');
      use(inputs[i], JSPrecedence.ASSIGNMENT_PRECEDENCE);
    }
    buffer.add(")");
  }

  void define(HInstruction instruction) {
    buffer.add('var ${temporary(instruction)} = ');
    visit(instruction, JSPrecedence.ASSIGNMENT_PRECEDENCE);
  }

  void use(HInstruction argument, int expectedPrecedence) {
    if (argument.generateAtUseSite()) {
      visit(argument, expectedPrecedence);
    } else {
      buffer.add(temporary(argument));
    }
  }

  visit(HInstruction node, int expectedPrecedence) {
    int oldPrecedence = this.expectedPrecedence;
    this.expectedPrecedence = expectedPrecedence;
    node.accept(this);
    this.expectedPrecedence = oldPrecedence;
  }

  void handleLabeledBlock(HBasicBlock node) {
    HLabeledBlockInformation labeledBlockInfo = node.labeledBlockInformation;
    if (labeledBlockInfo.start === node) {
      addIndentation();
      for (SourceString label in labeledBlockInfo.labels) {
        addLabel(label);
        buffer.add(":");
      }
      buffer.add("{\n");
      indent++;
    } else {
      assert(labeledBlockInfo.end === node);
      assert((){
        // Check that this block is (transitively) dominated by the start block.
        HBasicBlock block = node;
        while (block.dominator !== null) {
          block = block.dominator;
          if (block === labeledBlockInfo.start) return true;
        }
        return false;
      });
      indent--;
      addIndentation();
      buffer.add("}\n");
    }
  }


  visitBasicBlock(HBasicBlock node) {
    if (!subGraph.contains(node)) return;

    currentBlock = node;

    if (node.hasLabeledBlockInformation()) {
      handleLabeledBlock(node);
    } else if (currentBlock.isLoopHeader()) {
      // While loop will be closed by the conditional loop-branch.
      // TODO(floitsch): HACK HACK HACK.
      beginLoop(node);
    }

    HInstruction instruction = node.first;
    while (instruction != null) {
      if (instruction is HGoto || instruction is HExit || instruction is HTry) {
        visit(instruction, JSPrecedence.STATEMENT_PRECEDENCE);
        return;
      } else if (!instruction.generateAtUseSite()) {
        if (instruction is !HIf && instruction is !HBailoutTarget) {
          addIndentation();
        }
        if (instruction.usedBy.isEmpty() || instruction is HLocal) {
          visit(instruction, JSPrecedence.STATEMENT_PRECEDENCE);
        } else {
          define(instruction);
        }
        // Control flow instructions know how to handle ';'.
        if (instruction is !HControlFlow && instruction is !HBailoutTarget) {
          buffer.add(';\n');
        }
      } else if (instruction is HIf) {
        HIf hif = instruction;
        // The "if" is implementing part of a logical expression.
        // Skip directly forward to to its latest successor, since everything
        // in-between must also be generateAtUseSite.
        assert(hif.trueBranch.id < hif.falseBranch.id);
        visitBasicBlock(hif.falseBranch);
        return;
      }
      instruction = instruction.next;
    }
  }

  visitInvokeBinary(HInvokeBinary node, String op) {
    if (node.builtin) {
      JSBinaryOperatorPrecedence operatorPrecedences = JSPrecedence.binary[op];
      beginExpression(operatorPrecedences.precedence);
      use(node.left, operatorPrecedences.left);
      buffer.add(' $op ');
      use(node.right, operatorPrecedences.right);
      endExpression(operatorPrecedences.precedence);
    } else {
      visitInvokeStatic(node);
    }
  }

  visitInvokeUnary(HInvokeUnary node, String op) {
    if (node.builtin) {
      beginExpression(JSPrecedence.PREFIX_PRECEDENCE);
      buffer.add('$op');
      use(node.operand, JSPrecedence.PREFIX_PRECEDENCE);
      endExpression(JSPrecedence.PREFIX_PRECEDENCE);
    } else {
      visitInvokeStatic(node);
    }
  }

  visitEquals(HEquals node) {
    if (node.builtin) {
      beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
      use(node.left, JSPrecedence.EQUALITY_PRECEDENCE);
      buffer.add(' === ');
      use(node.right, JSPrecedence.RELATIONAL_PRECEDENCE);
      endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    } else if (node.element === equalsNullElement) {
      beginExpression(JSPrecedence.CALL_PRECEDENCE);
      use(node.target, JSPrecedence.CALL_PRECEDENCE);
      buffer.add('(');
      use(node.left, JSPrecedence.ASSIGNMENT_PRECEDENCE);
      buffer.add(')');
      endExpression(JSPrecedence.CALL_PRECEDENCE);
    } else {
      visitInvokeStatic(node);
    }
  }

  visitAdd(HAdd node)               => visitInvokeBinary(node, '+');
  visitDivide(HDivide node)         => visitInvokeBinary(node, '/');
  visitMultiply(HMultiply node)     => visitInvokeBinary(node, '*');
  visitSubtract(HSubtract node)     => visitInvokeBinary(node, '-');
  // Truncating divide does not have a JS equivalent.
  visitTruncatingDivide(HTruncatingDivide node) => visitInvokeStatic(node);
  // Modulo cannot be mapped to the native operator (different semantics).
  visitModulo(HModulo node)                     => visitInvokeStatic(node);

  visitBitAnd(HBitAnd node)         => visitInvokeBinary(node, '&');
  visitBitNot(HBitNot node)         => visitInvokeUnary(node, '~');
  visitBitOr(HBitOr node)           => visitInvokeBinary(node, '|');
  visitBitXor(HBitXor node)         => visitInvokeBinary(node, '^');
  visitShiftRight(HShiftRight node) => visitInvokeBinary(node, '>>');

  // Shift left cannot be mapped to the native operator (different semantics).
  visitShiftLeft(HShiftLeft node)   => visitInvokeStatic(node);

  visitNegate(HNegate node)         => visitInvokeUnary(node, '-');

  visitIdentity(HIdentity node)         => visitInvokeBinary(node, '===');
  visitLess(HLess node)                 => visitInvokeBinary(node, '<');
  visitLessEqual(HLessEqual node)       => visitInvokeBinary(node, '<=');
  visitGreater(HGreater node)           => visitInvokeBinary(node, '>');
  visitGreaterEqual(HGreaterEqual node) => visitInvokeBinary(node, '>=');

  visitLogicalOperator(HLogicalOperator node) {
    JSBinaryOperatorPrecedence operatorPrecedence =
        JSPrecedence.binary[node.operation];
    beginExpression(operatorPrecedence.precedence);
    use(node.left, operatorPrecedence.left);
    buffer.add(" ${node.operation} ");
    use(node.right, operatorPrecedence.right);
    endExpression(operatorPrecedence.precedence);
  }

  visitBoolify(HBoolify node) {
    beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    assert(node.inputs.length == 1);
    use(node.inputs[0], JSPrecedence.EQUALITY_PRECEDENCE);
    buffer.add(' === true');
    endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
  }

  visitExit(HExit node) {
    // Don't do anything.
  }

  visitGoto(HGoto node) {
    assert(currentBlock.successors.length == 1);
    List<HBasicBlock> dominated = currentBlock.dominatedBlocks;
    // With the exception of the entry-node which dominates its successor
    // and the exit node, no block finishing with a 'goto' can have more than
    // one dominated block (since it has only one successor).
    // If the successor is dominated by another block, then the other block
    // is responsible for visiting the successor.
    if (dominated.isEmpty()) return;
    if (dominated.length > 2) unreachable();
    if (dominated.length == 2 && currentBlock !== currentGraph.entry) {
      unreachable();
    }
    assert(dominated[0] == currentBlock.successors[0]);
    visitBasicBlock(dominated[0]);
  }

  // Used to write the name of labels.
  // The default implementation uses the unmodified Dart label name.
  // Specializations might change this.
  void addLabel(SourceString label) {
    buffer.add(label.slowToString());
  }

  visitBreak(HBreak node) {
    assert(currentBlock.successors.length == 1);
    // No block finishing with a 'break' can have more than
    // one dominated block (since it has only one successor).
    // If the successor is dominated by another block, then the other block
    // is responsible for visiting the successor.
    List<HBasicBlock> dominated = currentBlock.dominatedBlocks;
    assert(dominated.isEmpty());
    // Otherwise we would have bailed out in the builder.
    addIndentation();
    buffer.add("break");
    if (node.label !== null) {
      buffer.add(" ");
      addLabel(node.label);
    }
    buffer.add(";\n");
  }

  visitTry(HTry node) {
    addIndentation();
    buffer.add('try {\n');
    indent++;
    List<HBasicBlock> successors = node.block.successors;
    visitBasicBlock(successors[0]);
    indent--;

    if (node.finallyBlock != successors[1]) {
      // Printing the catch part.
      addIndentation();
      String name = temporary(node.exception);
      parameterNames[node.exception.element] = name;
      buffer.add('} catch ($name) {\n');
      indent++;
      addIndentation();
      visitBasicBlock(successors[1]);
      parameterNames.remove(node.exception.element);
      indent--;
    }

    if (node.finallyBlock != null) {
      addIndentation();
      buffer.add('} finally {\n');
      indent++;
      visitBasicBlock(node.finallyBlock);
      indent--;
    }
    addIndentation();
    buffer.add('}\n');

    visitBasicBlock(node.joinBlock);
  }

  visitIf(HIf node) {
    List<HBasicBlock> dominated = node.block.dominatedBlocks;
    HIfBlockInformation info = node.blockInformation;
    startIf(node);
    assert(!node.generateAtUseSite());
    startThen(node);
    assert(node.thenBlock === dominated[0]);
    visitSubGraph(info.thenGraph);
    int preVisitedBlocks = 1;
    endThen(node);
    if (node.hasElse) {
      startElse(node);
      assert(node.elseBlock === dominated[1]);
      visitSubGraph(info.elseGraph);
      preVisitedBlocks = 2;
      endElse(node);
    }
    endIf(node);
    if (info.joinBlock !== null && info.joinBlock.dominator !== node.block) {
      // The join block is dominated by a block in one of the branches.
      // The subgraph traversal never reached it, so we visit it here
      // instead.
      visitBasicBlock(info.joinBlock);
    }

    // Visit all the dominated blocks that are not part of the then or else
    // branches, and is not the join block.
    // Depending on how the then/else branches terminate
    // (e.g., return/throw/break) there can be any number of these.
    int dominatedCount = dominated.length;
    for (int i = preVisitedBlocks; i < dominatedCount; i++) {
      HBasicBlock dominatedBlock = dominated[i];
      assert(dominatedBlock.dominator === node.block);
      visitBasicBlock(dominatedBlock);
    }
  }

  visitInvokeDynamicMethod(HInvokeDynamicMethod node) {
    beginExpression(JSPrecedence.CALL_PRECEDENCE);
    use(node.receiver, JSPrecedence.MEMBER_PRECEDENCE);
    buffer.add('.');
    // Avoid adding the generative constructor name to the list of
    // seen selectors.
    if (node.inputs[0] is HForeignNew) {
      // Remove 'this' from the number of arguments.
      int argumentCount = node.inputs.length - 1;
      buffer.add(compiler.namer.instanceMethodName(node.name, argumentCount));
      visitArguments(node.inputs);
    } else {
      buffer.add(compiler.namer.instanceMethodInvocationName(
          node.name, node.selector));
      visitArguments(node.inputs);
      compiler.registerDynamicInvocation(node.name, node.selector);
    }
    endExpression(JSPrecedence.CALL_PRECEDENCE);
  }

  visitInvokeDynamicSetter(HInvokeDynamicSetter node) {
    beginExpression(JSPrecedence.CALL_PRECEDENCE);
    use(node.receiver, JSPrecedence.MEMBER_PRECEDENCE);
    buffer.add('.');
    buffer.add(compiler.namer.setterName(node.name));
    visitArguments(node.inputs);
    compiler.registerDynamicSetter(node.name);
    endExpression(JSPrecedence.CALL_PRECEDENCE);
  }

  visitInvokeDynamicGetter(HInvokeDynamicGetter node) {
    beginExpression(JSPrecedence.CALL_PRECEDENCE);
    use(node.receiver, JSPrecedence.MEMBER_PRECEDENCE);
    buffer.add('.');
    buffer.add(compiler.namer.getterName(node.name));
    visitArguments(node.inputs);
    compiler.registerDynamicGetter(node.name);
    endExpression(JSPrecedence.CALL_PRECEDENCE);
  }

  visitInvokeClosure(HInvokeClosure node) {
    beginExpression(JSPrecedence.CALL_PRECEDENCE);
    use(node.receiver, JSPrecedence.MEMBER_PRECEDENCE);
    buffer.add('.');
    buffer.add(compiler.namer.closureInvocationName(node.selector));
    visitArguments(node.inputs);
    // TODO(floitsch): we should have a separate list for closure invocations.
    compiler.registerDynamicInvocation(Namer.CLOSURE_INVOCATION_NAME,
                                       node.selector);
    endExpression(JSPrecedence.CALL_PRECEDENCE);
  }

  visitInvokeStatic(HInvokeStatic node) {
    beginExpression(JSPrecedence.CALL_PRECEDENCE);
    use(node.target, JSPrecedence.CALL_PRECEDENCE);
    visitArguments(node.inputs);
    endExpression(JSPrecedence.CALL_PRECEDENCE);
  }

  visitInvokeSuper(HInvokeSuper node) {
    beginExpression(JSPrecedence.CALL_PRECEDENCE);
    Element superMethod = node.element;
    Element superClass = superMethod.enclosingElement;
    // Remove the element and 'this'.
    int argumentCount = node.inputs.length - 2;
    String className = compiler.namer.isolatePropertyAccess(superClass);
    String methodName = compiler.namer.instanceMethodName(
        superMethod.name, argumentCount);
    buffer.add('$className.prototype.$methodName.call');
    visitArguments(node.inputs);
    endExpression(JSPrecedence.CALL_PRECEDENCE);
    compiler.registerStaticUse(superMethod);
  }

  visitFieldGet(HFieldGet node) {
    String name = JsNames.getValid(node.element.name.slowToString());
    if (node.receiver !== null) {
      beginExpression(JSPrecedence.MEMBER_PRECEDENCE);
      use(node.receiver, JSPrecedence.MEMBER_PRECEDENCE);
      buffer.add('.');
      buffer.add(name);
      beginExpression(JSPrecedence.MEMBER_PRECEDENCE);
    } else {
      buffer.add(name);
    }
  }

  visitFieldSet(HFieldSet node) {
    if (node.receiver !== null) {
      beginExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
      use(node.receiver, JSPrecedence.MEMBER_PRECEDENCE);
      buffer.add('.');
    } else {
      // TODO(ngeoffray): Remove the 'var' once we don't globally box
      // variables used in a try/catch.
      buffer.add('var ');
    }
    String name = JsNames.getValid(node.element.name.slowToString());
    buffer.add(name);
    buffer.add(' = ');
    use(node.value, JSPrecedence.ASSIGNMENT_PRECEDENCE);
    if (node.receiver !== null) {
      endExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
    }
  }

  visitForeign(HForeign node) {
    String code = '${node.code}';
    List<HInstruction> inputs = node.inputs;
    for (int i = 0; i < inputs.length; i++) {
      HInstruction input = inputs[i];
      String name;
      if (input is HThis) {
        name = "this";
      } else if (input is HParameterValue) {
        HParameterValue parameter = input;
        name = parameterNames[parameter.element];
      } else if (input is HLoad) {
        HLoad load = input;
        name = local(input.local);
      } else {
        assert(!input.generateAtUseSite());
        name = temporary(input);
      }
      code = code.replaceAll('\$$i', name);
    }
    beginExpression(JSPrecedence.EXPRESSION_PRECEDENCE);
    buffer.add(code);
    endExpression(JSPrecedence.EXPRESSION_PRECEDENCE);
  }

  visitForeignNew(HForeignNew node) {
    String jsClassReference = compiler.namer.isolateAccess(node.element);
    beginExpression(JSPrecedence.MEMBER_PRECEDENCE);
    buffer.add('new $jsClassReference(');
    // We can't use 'visitArguments', since our arguments start at input[0].
    List<HInstruction> inputs = node.inputs;
    for (int i = 0; i < inputs.length; i++) {
      if (i != 0) buffer.add(', ');
      use(inputs[i], JSPrecedence.ASSIGNMENT_PRECEDENCE);
    }
    buffer.add(')');
    endExpression(JSPrecedence.MEMBER_PRECEDENCE);
  }

  visitLiteral(HLiteral node) {
    if (node.isLiteralNull()) {
      beginExpression(JSPrecedence.PREFIX_PRECEDENCE);
      buffer.add("void 0");
      endExpression(JSPrecedence.PREFIX_PRECEDENCE);
    } else if (node.value is num) {
      int precedence = JSPrecedence.PRIMARY_PRECEDENCE;
      if (node.value < 0 ||
          expectedPrecedence == JSPrecedence.MEMBER_PRECEDENCE) {
        // Negative constants are really unary minus operator expressions.
        // If the constant appear as a MemberExpression, it might be subject
        // to the '.' operator, which shouldn't be put next to a number
        // literal. It might be mistaken for a decimal point. Setting
        // precedence to PREFIX_PRECEDENCE forces parentheses in this case.
        precedence = JSPrecedence.PREFIX_PRECEDENCE;
      }
      beginExpression(precedence);
      buffer.add(node.value);
      endExpression(precedence);
    } else if (node.isLiteralString()) {
      DartString string = node.value;
      buffer.add("'");
      CompileTimeConstantHandler.writeEscapedString(string, buffer,
                                                    (String reason) {
        compiler.cancel(reason, instruction: node);
      });
      buffer.add("'");
    } else {
      buffer.add(node.value);
    }
  }

  visitLoopBranch(HLoopBranch node) {
    HBasicBlock branchBlock = currentBlock;
    handleLoopCondition(node);
    List<HBasicBlock> dominated = currentBlock.dominatedBlocks;
    // For a do while loop, the body has already been visited.
    if (!node.isDoWhile()) {
      visitBasicBlock(dominated[0]);
    }
    endLoop(node.block);
    visitBasicBlock(branchBlock.successors[1]);
    // With labeled breaks we can have more dominated blocks.
    if (dominated.length >= 3) {
      for (int i = 2; i < dominated.length; i++) {
        visitBasicBlock(dominated[i]);
      }
    }
  }

  visitNot(HNot node) {
    assert(node.inputs.length == 1);
    beginExpression(JSPrecedence.PREFIX_PRECEDENCE);
    buffer.add('!');
    use(node.inputs[0], JSPrecedence.PREFIX_PRECEDENCE);
    endExpression(JSPrecedence.PREFIX_PRECEDENCE);
  }

  visitParameterValue(HParameterValue node) {
    buffer.add(parameterNames[node.element]);
  }

  visitPhi(HPhi node) {
    unreachable();
  }

  visitReturn(HReturn node) {
    assert(node.inputs.length == 1);
    HInstruction input = node.inputs[0];
    if (input.isLiteralNull()) {
      buffer.add('return;\n');
    } else {
      buffer.add('return ');
      use(node.inputs[0], JSPrecedence.EXPRESSION_PRECEDENCE);
      buffer.add(';\n');
    }
  }

  visitThis(HThis node) {
    buffer.add('this');
  }

  visitThrow(HThrow node) {
    if (node.isRethrow) {
      buffer.add('throw ');
      use(node.inputs[0], JSPrecedence.EXPRESSION_PRECEDENCE);
    } else {
      generateThrowWithHelper('captureStackTrace', node.inputs[0]);
    }
    buffer.add(';\n');
  }

  visitBoundsCheck(HBoundsCheck node) {
    buffer.add('if (');
    use(node.index, JSPrecedence.RELATIONAL_PRECEDENCE);
    buffer.add(' < 0 || ');
    use(node.index, JSPrecedence.RELATIONAL_PRECEDENCE);
    buffer.add(' >= ');
    use(node.length, JSPrecedence.SHIFT_PRECEDENCE);
    buffer.add(") ");
    generateThrowWithHelper('ioore', node.index);
  }

  visitIntegerCheck(HIntegerCheck node) {
    buffer.add('if (');
    use(node.value, JSPrecedence.EQUALITY_PRECEDENCE);
    buffer.add(' !== (');
    use(node.value, JSPrecedence.BITWISE_OR_PRECEDENCE);
    buffer.add(" | 0)) ");
    generateThrowWithHelper('iae', node.value);
  }

  void generateThrowWithHelper(String helperName, HInstruction argument) {
    Element helper = compiler.findHelper(new SourceString(helperName));
    compiler.registerStaticUse(helper);
    buffer.add('throw ');
    beginExpression(JSPrecedence.EXPRESSION_PRECEDENCE);
    beginExpression(JSPrecedence.CALL_PRECEDENCE);
    buffer.add(compiler.namer.isolateAccess(helper));
    visitArguments([null, argument]);
    endExpression(JSPrecedence.CALL_PRECEDENCE);
    endExpression(JSPrecedence.EXPRESSION_PRECEDENCE);
  }

  void addIndentation() {
    for (int i = 0; i < indent; i++) {
      buffer.add('  ');
    }
  }

  void visitStatic(HStatic node) {
    compiler.registerStaticUse(node.element);
    buffer.add(compiler.namer.isolateAccess(node.element));
  }

  void visitStaticStore(HStaticStore node) {
    compiler.registerStaticUse(node.element);
    beginExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
    buffer.add(compiler.namer.isolateAccess(node.element));
    buffer.add(' = ');
    use(node.inputs[0], JSPrecedence.ASSIGNMENT_PRECEDENCE);
    endExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
  }

  void visitStore(HStore node) {
    if (node.local.declaredBy === node) {
      buffer.add('var ');
    } else {
      beginExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
    }
    buffer.add('${local(node.local)} = ');
    use(node.value, JSPrecedence.ASSIGNMENT_PRECEDENCE);
    if (node.local.declaredBy !== node) {
      endExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
    }
  }

  void visitLoad(HLoad node) {
    buffer.add('${local(node.local)}');
  }

  void visitLocal(HLocal node) {
    buffer.add('var ${local(node)}');
  }

  void visitLiteralList(HLiteralList node) {
    if (node.isConst) {
      // TODO(floitsch): Remove this when CTC handles arrays.
      SourceString name = new SourceString('makeLiteralListConst');
      Element helper = compiler.findHelper(name);
      compiler.registerStaticUse(helper);
      beginExpression(JSPrecedence.CALL_PRECEDENCE);
      buffer.add(compiler.namer.isolateAccess(helper));
      buffer.add('(');
      generateArrayLiteral(node);
      buffer.add(')');
      endExpression(JSPrecedence.CALL_PRECEDENCE);
    } else {
      generateArrayLiteral(node);
    }
  }

  void generateArrayLiteral(HLiteralList node) {
    buffer.add('[');
    int len = node.inputs.length;
    for (int i = 0; i < len; i++) {
      if (i != 0) buffer.add(', ');
      use(node.inputs[i], JSPrecedence.ASSIGNMENT_PRECEDENCE);
    }
    buffer.add(']');
  }

  void visitIndex(HIndex node) {
    if (node.builtin) {
      beginExpression(JSPrecedence.MEMBER_PRECEDENCE);
      use(node.inputs[1], JSPrecedence.MEMBER_PRECEDENCE);
      buffer.add('[');
      use(node.inputs[2], JSPrecedence.EXPRESSION_PRECEDENCE);
      buffer.add(']');
      endExpression(JSPrecedence.MEMBER_PRECEDENCE);
    } else {
      visitInvokeStatic(node);
    }
  }

  void visitIndexAssign(HIndexAssign node) {
    if (node.builtin) {
      beginExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
      use(node.inputs[1], JSPrecedence.MEMBER_PRECEDENCE);
      buffer.add('[');
      use(node.inputs[2], JSPrecedence.EXPRESSION_PRECEDENCE);
      buffer.add('] = ');
      use(node.inputs[3], JSPrecedence.ASSIGNMENT_PRECEDENCE);
      endExpression(JSPrecedence.ASSIGNMENT_PRECEDENCE);
    } else {
      visitInvokeStatic(node);
    }
  }

  void visitInvokeInterceptor(HInvokeInterceptor node) {
    if (node.builtinJsName != null) {
      beginExpression(JSPrecedence.CALL_PRECEDENCE);
      use(node.inputs[1], JSPrecedence.MEMBER_PRECEDENCE);
      buffer.add('.');
      buffer.add(node.builtinJsName);
      if (node.getter) return;
      buffer.add('(');
      for (int i = 2; i < node.inputs.length; i++) {
        if (i != 2) buffer.add(', ');
        use(node.inputs[i], JSPrecedence.ASSIGNMENT_PRECEDENCE);
      }
      buffer.add(")");
      endExpression(JSPrecedence.CALL_PRECEDENCE);
    } else {
      return visitInvokeStatic(node);
    }
  }

  void checkInt(HInstruction input, String cmp) {
    beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    use(input, JSPrecedence.EQUALITY_PRECEDENCE);
    buffer.add(' $cmp (');
    use(input, JSPrecedence.BITWISE_OR_PRECEDENCE);
    buffer.add(' | 0)');
    endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
  }

  void checkNum(HInstruction input, String cmp) {
    beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    buffer.add('typeof ');
    use(input, JSPrecedence.PREFIX_PRECEDENCE);
    buffer.add(" $cmp 'number'");
    endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
  }

  void checkDouble(HInstruction input, String cmp) {
    checkNum(input, cmp);
  }

  void checkString(HInstruction input, String cmp) {
    beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    buffer.add('typeof ');
    use(input, JSPrecedence.PREFIX_PRECEDENCE);
    buffer.add(" $cmp 'string'");
    endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
  }

  void checkBool(HInstruction input, String cmp) {
    beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    buffer.add('typeof ');
    use(input, JSPrecedence.PREFIX_PRECEDENCE);
    buffer.add(" $cmp 'boolean'");
    endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
  }

  void checkObject(HInstruction input, String cmp) {
    beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    buffer.add('typeof ');
    use(input, JSPrecedence.PREFIX_PRECEDENCE);
    buffer.add(" $cmp 'object'");
    endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
  }

  void checkArray(HInstruction input, String cmp) {
    beginExpression(JSPrecedence.EQUALITY_PRECEDENCE);
    use(input, JSPrecedence.MEMBER_PRECEDENCE);
    buffer.add('.constructor $cmp Array');
    endExpression(JSPrecedence.EQUALITY_PRECEDENCE);
  }

  void visitIs(HIs node) {
    ClassElement element = node.typeExpression;
    LibraryElement coreLibrary = compiler.coreLibrary;
    ClassElement objectClass = coreLibrary.find(const SourceString('Object'));
    HInstruction input = node.expression;
    if (element == objectClass) {
      // TODO(ahe): This probably belongs in the constant folder.
      buffer.add('true');
    } else if (element == coreLibrary.find(const SourceString('String'))) {
      checkString(input, '===');
    } else if (element == coreLibrary.find(const SourceString('double'))) {
      checkDouble(input, '===');
    } else if (element == coreLibrary.find(const SourceString('num'))) {
      checkNum(input, '===');
    } else if (element == coreLibrary.find(const SourceString('bool'))) {
      checkBool(input, '===');
    } else if (element == coreLibrary.find(const SourceString('int'))) {
      beginExpression(JSPrecedence.LOGICAL_AND_PRECEDENCE);
      checkNum(input, '===');
      buffer.add(' && ');
      checkInt(input, '===');
      endExpression(JSPrecedence.LOGICAL_AND_PRECEDENCE);
    } else {
      beginExpression(JSPrecedence.LOGICAL_AND_PRECEDENCE);
      if (isStringSupertype(element)) {
        checkString(input, '===');
        buffer.add(' || ');
      }
      checkObject(input, '===');
      buffer.add(' && ');
      int precedence = JSPrecedence.PREFIX_PRECEDENCE;
      bool endParen = false;
      if (isListOrSupertype(element)) {
        buffer.add("(");
        endParen = true;
        beginExpression(JSPrecedence.LOGICAL_OR_PRECEDENCE);
        checkArray(input, '===');
        buffer.add(' || ');
        precedence = JSPrecedence.LOGICAL_OR_PRECEDENCE;
      } else if (element.isNative() || isSupertypeOfNativeClass(element)) {
        buffer.add("(");
        endParen = true;
      } else {
        beginExpression(precedence);
      }
      buffer.add('!!');
      use(input, JSPrecedence.MEMBER_PRECEDENCE);
      buffer.add('.');
      buffer.add(compiler.namer.operatorIs(node.typeExpression));
      if (element.isNative() || isSupertypeOfNativeClass(element)) {
        buffer.add(' || ');
        beginExpression(JSPrecedence.LOGICAL_AND_PRECEDENCE);
        // First check if the object is not a Dart object. If the
        // object is a Dart object, we know the property check was
        // sufficient.
        buffer.add('!');
        use(input, JSPrecedence.MEMBER_PRECEDENCE);
        buffer.add('.');
        buffer.add(compiler.namer.operatorIs(objectClass));
        buffer.add(' && ');
        buffer.add(compiler.emitter.nativeEmitter.dynamicIsCheckName);
        buffer.add('(');
        use(input, JSPrecedence.MEMBER_PRECEDENCE);
        buffer.add(", '${compiler.namer.operatorIs(node.typeExpression)}')");
        endExpression(JSPrecedence.LOGICAL_AND_PRECEDENCE);
      }
      endExpression(precedence);
      if (endParen) buffer.add(')');
      endExpression(JSPrecedence.LOGICAL_AND_PRECEDENCE);
    }
  }

  bool isStringSupertype(ClassElement cls) {
    LibraryElement coreLibrary = compiler.coreLibrary;
    return (cls == coreLibrary.find(const SourceString('Comparable')))
      || (cls == coreLibrary.find(const SourceString('Hashable')))
      || (cls == coreLibrary.find(const SourceString('Pattern')));
  }

  bool isListOrSupertype(ClassElement cls) {
    LibraryElement coreLibrary = compiler.coreLibrary;
    return (cls == coreLibrary.find(const SourceString('List')))
      || (cls == coreLibrary.find(const SourceString('Collection')))
      || (cls == coreLibrary.find(const SourceString('Iterable')));
  }

  bool isSupertypeOfNativeClass(ClassElement cls) {
    // TODO(ngeoffray): Check all types that are super types of native
    // classes.
    return true;
  }
}

class SsaOptimizedCodeGenerator extends SsaCodeGenerator {
  final List<HTypeGuard> guards;
  int state = 0;

  SsaOptimizedCodeGenerator(compiler, work, buffer, parameters, parameterNames)
    : super(compiler, work, buffer, parameters, parameterNames),
      guards = <HTypeGuard>[];

  void beginGraph(HGraph graph) {}
  void endGraph(HGraph graph) {}

  void bailout(HTypeGuard guard, String reason) {
    guards.add(guard);
    HInstruction input = guard.guarded;
    Namer namer = compiler.namer;
    Element element = work.element;
    buffer.add('return ');
    if (element.isInstanceMember()) {
      // TODO(ngeoffray): This does not work in case we come from a
      // super call. We must make bailout names unique.
      buffer.add('this.${namer.getBailoutName(element)}');
    } else {
      buffer.add(namer.isolateBailoutAccess(element));
    }
    int parametersCount = parameterNames.length;
    buffer.add('($parameters');
    if (parametersCount != 0) buffer.add(', ');
    if (guard.guarded is !HParameterValue) {
      buffer.add('${++state}');
      bool first = true;
      // TODO(ngeoffray): if the bailout method takes more arguments,
      // fill the remaining arguments with undefined.
      // TODO(ngeoffray): try to put a variable at a deterministic
      // location, so that multiple bailout calls put the variable at
      // the same parameter index.
      for (int i = 0; i < guard.inputs.length; i++) {
        HInstruction input = guard.inputs[i];
        buffer.add(', ');
        use(guard.inputs[i], JSPrecedence.ASSIGNMENT_PRECEDENCE);
      }
    } else {
      assert(guard.guarded is HParameterValue);
      buffer.add(' 0');
    }
    buffer.add(')');
  }

  void visitTypeGuard(HTypeGuard node) {
    HInstruction input = node.guarded;
    assert(!input.generateAtUseSite() || input is HParameterValue);
    if (node.isInteger()) {
      buffer.add('if (');
      checkInt(input, '!==');
      buffer.add(') ');
      bailout(node, 'Not an integer');
    } else if (node.isNumber()) {
      buffer.add('if (');
      checkNum(input, '!==');
      buffer.add(') ');
      bailout(node, 'Not a number');
    } else if (node.isBoolean()) {
      buffer.add('if (');
      checkBool(input, '!==');
      buffer.add(') ');
      bailout(node, 'Not a boolean');
    } else if (node.isString()) {
      buffer.add('if (');
      checkString(input, '!==');
      buffer.add(') ');
      bailout(node, 'Not a string');
    } else if (node.isArray()) {
      buffer.add('if (');
      checkObject(input, '!==');
      buffer.add('||');
      checkArray(input, '!==');
      buffer.add(') ');
      bailout(node, 'Not an array');
    } else if (node.isStringOrArray()) {
      buffer.add('if (');
      checkString(input, '!==');
      buffer.add(' && (');
      checkObject(input, '!==');
      buffer.add('||');
      checkArray(input, '!==');
      buffer.add(')) ');
      bailout(node, 'Not a string or array');
    } else {
      unreachable();
    }
  }

  void beginLoop(HBasicBlock block) {
    addIndentation();
    for (SourceString label in block.loopInformation.labels) {
      buffer.add("${label.slowToString()}:");
    }
    buffer.add('while (true) {\n');
    indent++;
  }

  void endLoop(HBasicBlock block) {
    indent--;
    addIndentation();
    buffer.add('}\n');  // Close 'while' loop.
  }

  void handleLoopCondition(HLoopBranch node) {
    buffer.add('if (!');
    use(node.inputs[0], JSPrecedence.PREFIX_PRECEDENCE);
    buffer.add(') break;\n');
  }

  void startIf(HIf node) {
  }

  void endIf(HIf node) {
    indent--;
    addIndentation();
    buffer.add('}\n');
  }

  void startThen(HIf node) {
    addIndentation();
    buffer.add('if (');
    use(node.inputs[0], JSPrecedence.EXPRESSION_PRECEDENCE);
    buffer.add(') {\n');
    indent++;
  }

  void endThen(HIf node) {
  }

  void startElse(HIf node) {
    indent--;
    addIndentation();
    buffer.add('} else {\n');
    indent++;
  }

  void endElse(HIf node) {
  }

  void visitBailoutTarget(HBailoutTarget target) {
    compiler.internalError('Bailout target in an optimized method');
  }
}

class SsaUnoptimizedCodeGenerator extends SsaCodeGenerator {

  final StringBuffer setup;
  final List<String> labels;
  int labelId = 0;
  int maxBailoutParameters = 0;

  SsaUnoptimizedCodeGenerator(
      compiler, work, buffer, parameters, parameterNames)
    : super(compiler, work, buffer, parameters, parameterNames),
      setup = new StringBuffer(),
      labels = <String>[];

  String pushLabel() {
    String label = 'L${labelId++}';
    labels.addLast(label);
    return label;
  }

  String popLabel() {
    return labels.removeLast();
  }

  String currentLabel() {
    return labels.last();
  }

  void beginGraph(HGraph graph) {
    if (!graph.entry.hasBailouts()) return;
    addIndentation();
    buffer.add('switch (state) {\n');
    indent++;
    addIndentation();
    buffer.add('case 0:\n');
    indent++;

    // The setup phase of a bailout function sets up the environment for
    // each bailout target. Each bailout target will populate this
    // setup phase. It is put at the beginning of the function.
    setup.add('  switch (state) {\n');
  }

  void endGraph(HGraph graph) {
    if (!graph.entry.hasBailouts()) return;
    indent--; // Close original case.
    indent--;
    addIndentation();
    buffer.add('}\n');  // Close 'switch'.
    setup.add('  }\n');
  }

  void visitTypeGuard(HTypeGuard guard) {
    compiler.internalError('Type guard in an unoptimized method');
  }

  void visitBailoutTarget(HBailoutTarget node) {
    indent--;
    addIndentation();
    buffer.add('case ${node.state}:\n');
    indent++;
    addIndentation();
    buffer.add('state = 0;\n');

    setup.add('    case ${node.state}:\n');
    int i = 0;
    for (HInstruction input in node.inputs) {
      setup.add('      ${temporary(input)} = env$i;\n');
      if (input is HLoad) {
        // We get the load of a phi that was turned into a local in
        // the environment. Update the local with that load.
        HLoad load = input;
        setup.add('      ${local(load.local)} = env$i;\n');
      }
      i++;
    }
    if (i > maxBailoutParameters) maxBailoutParameters = i;
    setup.add('      break;\n');
  }

  void startBailoutCase(List<HBailoutTarget> bailouts1,
                        List<HBailoutTarget> bailouts2) {
    indent--;
    handleBailoutCase(bailouts1);
    handleBailoutCase(bailouts2);
    indent++;
  }

  void handleBailoutCase(List<HBailoutTarget> bailouts) {
    for (int i = 0, len = bailouts.length; i < len; i++) {
      addIndentation();
      buffer.add('case ${bailouts[i].state}:\n');
    }
  }

  void startBailoutSwitch() {
    addIndentation();
    buffer.add('switch (state) {\n');
    indent++;
    addIndentation();
    buffer.add('case 0:\n');
    indent++;
  }

  void endBailoutSwitch() {
    indent--; // Close 'case'.
    indent--;
    addIndentation();
    buffer.add('}\n');  // Close 'switch'.
  }

  // Adds a "$" in front of names of labels from the original source.
  // This avoids conflicts with labels introduced by bailouts, which
  // starts with a non-"$" character.
  void addLabel(SourceString label) {
    buffer.add("\$$label");
  }

  void beginLoop(HBasicBlock block) {
    // TODO(ngeoffray): Don't put labels on loops that don't bailout.
    String newLabel = pushLabel();
    if (block.hasBailouts()) {
      startBailoutCase(block.bailouts, const <HBailoutTarget>[]);
    }

    addIndentation();
    for (SourceString label in block.loopInformation.labels) {
      addLabel(label);
      buffer.add(":");
    }
    buffer.add('$newLabel: while (true) {\n');
    indent++;

    if (block.hasBailouts()) {
      startBailoutSwitch();
    }
  }

  void endLoop(HBasicBlock block) {
    popLabel();
    HBasicBlock header = block.isLoopHeader() ? block : block.parentLoopHeader;
    if (header.hasBailouts()) {
      endBailoutSwitch();
    }
    indent--;
    addIndentation();
    buffer.add('}\n');  // Close 'while'.
  }

  void handleLoopCondition(HLoopBranch node) {
    buffer.add('if (!');
    use(node.inputs[0], JSPrecedence.PREFIX_PRECEDENCE);
    buffer.add(') break ${currentLabel()};\n');
  }

  void startIf(HIf node) {
    bool hasBailouts = node.thenBlock.hasBailouts()
        || (node.hasElse && node.elseBlock.hasBailouts());
    if (hasBailouts) {
      startBailoutCase(node.thenBlock.bailouts,
          node.hasElse ? node.elseBlock.bailouts : const <HBailoutTarget>[]);
    }
  }

  void endIf(HIf node) {
    indent--;
    addIndentation();
    buffer.add('}\n');
  }

  void startThen(HIf node) {
    addIndentation();
    bool hasBailouts = node.thenBlock.hasBailouts()
        || (node.hasElse && node.elseBlock.hasBailouts());
    buffer.add('if (');
    int precedence = JSPrecedence.EXPRESSION_PRECEDENCE;
    if (hasBailouts) {
      // TODO(ngeoffray): Put the condition initialization in the
      // [setup] buffer.
      List<HBailoutTarget> bailouts = node.thenBlock.bailouts;
      for (int i = 0, len = bailouts.length; i < len; i++) {
        buffer.add('state == ${bailouts[i].state} || ');
      }
      buffer.add('(state == 0 && ');
      precedence = JSPrecedence.BITWISE_OR_PRECEDENCE;
    }
    use(node.inputs[0], precedence);
    if (hasBailouts) {
      buffer.add(')');
    }
    buffer.add(') {\n');
    indent++;
    if (node.thenBlock.hasBailouts()) {
      startBailoutSwitch();
    }
  }

  void endThen(HIf node) {
    if (node.thenBlock.hasBailouts()) {
      endBailoutSwitch();
    }
  }

  void startElse(HIf node) {
    indent--;
    addIndentation();
    buffer.add('} else {\n');
    indent++;
    if (node.elseBlock.hasBailouts()) {
      startBailoutSwitch();
    }
  }

  void endElse(HIf node) {
    if (node.elseBlock.hasBailouts()) {
      endBailoutSwitch();
    }
  }
}
