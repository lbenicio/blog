---
title: "Building A Serverless Function Orchestrator With Workflow Dag And Checkpointing"
description: "A comprehensive technical exploration of building a serverless function orchestrator with workflow dag and checkpointing, covering key concepts, practical implementations, and real-world applications."
date: "2024-11-24"
author: "Leonardo Benicio"
tags: ["technical", "computer-science"]
categories: ["theory", "algorithms"]
draft: false
cover: "/static/images/blog/building-a-serverless-function-orchestrator-with-workflow-dag-and-checkpointing.png"
coverAlt: "Technical visualization representing building a serverless function orchestrator with workflow dag and checkpointing"
---

This is an excellent topic with a sharp, critical lens. Expanding this introduction to a full, in-depth blog post requires unpacking each metaphor, providing concrete horror stories, and offering a path forward. Below is a comprehensive expansion, structured for depth, technical rigor, and readability. I have maintained the original voice while adding substantial new material.

---

### The Fragile Promise of Serverless: Why Your "Simple" Workflow is a Distributed Systems Nightmare

You’ve been there. You start with a single serverless function. It’s beautiful. It’s stateless. It scales to zero. You don’t have to provision a single server. The developer experience is intoxicating. You push a code change, and within seconds, your function is live, handling requests, and you’re blissfully unaware of the underlying Kubernetes clusters, operating system patches, or network configurations that someone else is managing. This is the honeymoon phase of serverless, a period of pure, unadulterated productivity.

Then, the business logic gets a little… complicated.

“We need to process the image, then generate a thumbnail, then run OCR, then send a notification, but only if the user’s preferences are set, and we need to retry the OCR if it fails.”

Suddenly, your clean, single-function architecture is a tangled web of AWS Step Functions, SQS queues, Lambda invocations, and callback URLs. You’re not building a serverless application anymore; you’re building a distributed systems orchestration layer, often with a tool—like a state machine in a UI console—that wasn’t designed for the complex, dynamic, and highly resilient workflows your product demands. The simplicity you once felt evaporates, replaced by a thick fog of JSON configuration, dead-letter queues, and idempotency keys.

The promise of serverless was simplicity. The reality, for anyone building beyond a CRUD API, is an explosion of complexity around state management, error handling, and execution control. You end up with what I call "Configuration Hell": a sprawling JSON definition for your workflow that is impossible to debug, version control effectively, or test. It’s a new kind of technical debt, one that hides not in your code, but in the fragile, implicit connections between ephemeral services.

This is the central paradox of modern serverless development: the compute is ephemeral, but the workflows must be durable. We have fallen in love with the stateless function, but we have built stateful businesses. We have embraced the "function" as a unit of compute, but we have neglected the "orchestrator" as a unit of control. We are trying to conduct a symphony by shouting individual instructions to the musicians, hoping they remember the right tune. The result is rarely a harmonious concerto; more often, it’s a cacophony of failed retries and corrupted state.

**Why This Matters: The Cost of Amnesia**

The core problem is amnesia. A serverless function, by design, has no memory of its past. It is invoked, it runs, it dies. When you need to execute a series of functions where the output of one is the input of another, you are building a chain of amnesia, where the only "memory" is the data passed through the chain. This is fundamentally different from a monolithic application where an in-memory object can hold state for the duration of a request. In a serverless workflow, every single interaction across functions is an explicit, network-bound, potentially failing handoff.

This architectural amnesia has profound consequences. Consider a simple e-commerce order flow: a user places an order, we need to charge their card, update inventory, send a confirmation email, and schedule a shipment. In a monolith, this is a single transaction, a series of database writes within a single process. In a serverless world, this becomes a distributed saga. The "charge card" function succeeds, but the "update inventory" function fails. Suddenly, your customer has been charged, but the inventory hasn't been decremented. The system has no automatic "undo." You have created a resource leak, a ghost order that will haunt your accounting department.

You now have to implement a compensating transaction. You need a separate function that, when the workflow fails at step three, can roll back step one. This is not just hard; it is conceptually a new skill. You are now a distributed systems engineer, whether you like it or not. You must reason about partial failures, eventual consistency, and the subtle horror of exactly-once execution semantics in a network where failures are not the exception, but the rule. The "simple" workflow has become a dissertation on the fallacies of distributed computing.

#### The Allure of the Single Function: A Case Study in Innocence

To understand how quickly things go wrong, let's build a trivial application. Imagine you work for a photo-sharing app called "SnapVault." The initial requirement is simple: when a user uploads a photo, we must create a thumbnail.

**The Naive Implementation (A Single Lambda):**

```python
import boto3
from PIL import Image
import io

s3 = boto3.client('s3')

def lambda_handler(event, context):
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']

    # Download the original image
    response = s3.get_object(Bucket=bucket, Key=key)
    image_bytes = response['Body'].read()

    # Create a thumbnail
    img = Image.open(io.BytesIO(image_bytes))
    img.thumbnail((128, 128))
    buffer = io.BytesIO()
    img.save(buffer, 'JPEG')
    buffer.seek(0)

    # Upload the thumbnail
    thumbnail_key = f"thumbnails/{key.split('/')[-1]}"
    s3.put_object(Bucket=bucket, Key=thumbnail_key, Body=buffer)

    return {'statusCode': 200, 'body': 'Thumbnail created'}
```

This is beautiful. It’s one function, one trigger. It’s testable, it’s simple, and it works perfectly in 99% of cases. The developer is happy. The manager is happy. The CEO is happy. You deploy it and move on.

#### The Drift: The First Symptom of Complexity

Then, the product manager arrives with a new requirement. "Great work on the thumbnails," they say. "But we need to also run Optical Character Recognition (OCR) on the images to extract tags. And only if the OCR finds text, we should send a push notification to the user. Oh, and the OCR is a third-party API that costs money, so we need to make sure we only call it once, and we need to retry up to three times if it fails."

The single function can no longer handle this. The function would have to wait synchronously for the OCR API, which could take seconds, and you'd be paying for idle Lambda time. More importantly, if the notification fails, do you need to re-run the OCR? No, you don't. You need granular error handling. You need to separate the concerns.

So, you decompose. You create three functions:

1.  `generate_thumbnail`: (The original function, slightly modified)
2.  `run_ocr`: (Calls the third-party API, returns text)
3.  `send_notification`: (Sends a push notification)

Now, you need a way to chain them. The output of `generate_thumbnail` should be the input of `run_ocr`. The output of `run_ocr` should conditionally trigger `send_notification`. You look at AWS Step Functions. You start to write a state machine definition.

```json
{
  "Comment": "My first workflow... and my last moment of peace",
  "StartAt": "GenerateThumbnail",
  "States": {
    "GenerateThumbnail": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:us-east-1:123456789012:function:generate_thumbnail",
      "Next": "RunOCR"
    },
    "RunOCR": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:us-east-1:123456789012:function:run_ocr",
      "Retry": [
        {
          "ErrorEquals": ["States.ALL"],
          "IntervalSeconds": 2,
          "MaxAttempts": 3,
          "BackoffRate": 2.0
        }
      ],
      "Next": "CheckOCRResult"
    },
    "CheckOCRResult": {
      "Type": "Choice",
      "Choices": [
        {
          "Variable": "$.has_text",
          "BooleanEquals": true,
          "Next": "SendNotification"
        },
        {
          "Variable": "$.has_text",
          "BooleanEquals": false,
          "Next": "WorkflowComplete"
        }
      ]
    },
    "SendNotification": {
      "Type": "Task",
      "Resource": "arn:aws:lambda:us-east-1:123456789012:function:send_notification",
      "End": true
    },
    "WorkflowComplete": {
      "Type": "Succeed"
    }
  }
}
```

At first glance, it's clean. It's a flowchart in JSON. But this is where the nightmare begins. You have just traded one function for a distributed system defined by a configuration file. You have introduced state, retries, and conditional logic—all outside your codebase.

### Configuration Hell: The JSON Prison

This configuration file is now the heart of your application. It lives outside your version control repository (unless you explicitly extract it), it is not subject to the same linting, type-checking, or unit testing as your code, and its behavior is often opaque. Welcome to Configuration Hell.

**Problem 1: Debugging is a Nightmare**

The "CheckOCRResult" state uses a JSONPath expression `$.has_text`. If your `run_ocr` function returns a slightly different shape, like `{"ocr_result": {"has_text": true}}`, the Step Function silently fails. The state machine execution shows "CheckOCRResult" -> "WorkflowComplete" with no error, and you spend hours wondering why no notification was sent. The root cause is a data contract mismatch between two functions, but the error is invisible because the state machine gracefully chose the wrong path.

In a monolith, a similar bug would be caught by a type checker or a simple unit test. In this serverless workflow, the error is latent, hiding in a configuration file that only exists at runtime. You end up manually replaying executions, inspecting inputs and outputs, and debugging through the AWS console UI—a deeply unsatisfying and error-prone experience.

**Problem 2: Version Control is an Afterthought**

The JSON for your state machine is often stored as a resource in AWS CloudFormation or Terraform. It’s a massive string inside an Infrastructure-as-Code (IaC) template. Reviewing changes to this JSON is difficult. A Pull Request might say "Changed `$.has_text` to `$.data.ocr.has_text`", but understanding the _impact_ of that change requires visualizing the entire state machine diagram in your head. Did you introduce a new path? Did you accidentally create an infinite loop? Code review tools are not designed to diff state machines.

Furthermore, there is no way to "unit test" a state machine configuration. You can run integration tests that deploy the whole stack, but this is slow, expensive, and brittle. You lose the tight feedback loop that made serverless attractive in the first place.

**Problem 3: The Inability to Handle Dynamic Workflows**

The JSON state machine is a static Directed Acyclic Graph (DAG). You must define every path at compile time. But what if the workflow needs to be dynamic? What if the number of images to process is only known at runtime? What if the user’s subscription tier determines which steps are executed? What if you need to perform an OCR on multiple files in parallel, but the number of files is only known after the thumbnail step?

You can't easily express a "for each" loop in the static JSON. You end up hacking around this with "Map" states (which are still static in terms of the processing template) or by creating a "sub-workflow" that is called recursively. You are fighting the tool, bending its semantics to fit your business logic. This is the opposite of the "primitive match" you get with a general-purpose programming language.

### The Amnesia Deep Dive: State Management Without a Memory

The most insidious failure mode of these orchestrated serverless workflows is state corruption. Remember, each function is an amnesiac. It wakes up, does its job, and dies, forgetting everything except what was in the input payload.

**The Hot Potato of Data**

The entire state of your workflow is passed through the system as a "hot potato"—a payload that grows with every step. Your `run_ocr` function might need the original image key and the thumbnail key. It returns the original image key, the thumbnail key, and the OCR text. The next function, `send_notification`, needs the user ID (which was never passed along!), so you have to go back and modify `generate_thumbnail` to also pass the user ID.

This leads to a "state bloat" problem. The payload becomes a massive, deeply nested JSON object containing the entire history of the workflow. You are effectively building a log-structured merge tree using JSON keys. This is not an abstraction; it’s a leaky, fragile data structure. Any function that accidentally mutates a shared key can break the entire workflow for downstream consumers.

**The Saga Pattern: Compensation Compensation**

When a step fails, you need to roll back. But how? Because the functions have no memory, the orchestrator must know what to undo. This is the Saga pattern, and it's a core concept in distributed systems. However, implementing it correctly in a Step Functions JSON is incredibly hard.

Imagine your workflow has four steps:

1.  Reserve Funds (Debit account)
2.  Ship Item
3.  Update Inventory
4.  Send Confirmation

If step 3 fails, you must run a _compensating transaction_ for step 2 (Cancel Shipment) and step 1 (Release Funds). The Step Function must have a dedicated "Catch" block for every state, and that catch block must call a separate compensation function. You end up with a state machine definition that is twice as long as the happy path. The error handling logic is not in your code; it is in the configuration. You cannot test it locally. You have to deploy it to see if the compensation works, and if it fails, you have to manually intervene to fix the corrupted state.

This is terrifying for production systems. The "simple" serverless workflow has become a distributed transaction machine, and you have built it with JSON and hope.

### The Observability Void: When You Can't See the Forest for the Trees

In a monolithic application, observability is relatively straightforward. You have a single process, a single log stream, and a single trace. You can put a breakpoint in the middle of the transaction.

In a serverless workflow, the observability problem is multiplied. Each Lambda function has its own CloudWatch log group. The Step Function execution has its own event history. You have an SQS queue between steps that is mostly invisible to your standard tools. Correlating a single user request across all these disparate services is an exercise in stitching together timestamps and request IDs, hoping your platform's tracing library actually propagates the context correctly.

**The Distributed Tracing Myth**

Many teams rely on AWS X-Ray or other distributed tracing tools to solve this. In theory, they should work. In practice, they often fail because the tracing header is lost during the handoff between Lambda Step Function and the next Lambda. The Step Function itself may not propagate the trace ID correctly. You end up with "traces" that are just two isolated segments: one for the state machine execution, and one for the Lambda invocation, with no causal link to the original user request.

When a workflow fails, you are left with a binary state machine execution history that says "Task failed: RunOCR." But why did it fail? Was it a timeout? A permissions error? An API rate limit? You have to dive into the specific Lambda's CloudWatch logs, find the correct execution ID (which involves copying it from the Step Function execution history), and then manually search for the error message. This entire process can take 15 minutes for a single failure. Multiply that by dozens of failures per day, and you have a full-time job dedicated to reading logs.

### The Path Forward: Reclaiming the Orchestrator

So, is serverless doomed? No. The compute model is brilliant. The fault lies not in the functions themselves, but in the tools we use to orchestrate them. The solution is to stop trying to build distributed systems with static configuration files and start using actual programming languages for orchestration.

**Option 1: Embrace a Durable Execution Framework**

Frameworks like **Temporal**, **Azure Durable Functions**, or even custom state machines built with **AWS Step Functions SDK** (where you build the state machine dynamically from code) are far superior. Temporal, in particular, is a game-changer. It allows you to write a complete workflow as a single, linear piece of code.

```python
# This is your entire workflow, written as a single Python function.
@workflow.defn
class ImageProcessingWorkflow:
    @workflow.run
    async def run(self, image_key: str, user_id: str) -> str:
        # Step 1: Generate thumbnail
        thumbnail_key = await workflow.execute_activity(
            generate_thumbnail, image_key
        )

        # Step 2: Run OCR with retries
        ocr_text = await workflow.execute_activity(
            run_ocr, image_key,
            start_to_close_timeout=timedelta(seconds=30),
            retry_policy=RetryPolicy(maximum_attempts=3)
        )

        # Step 3: Conditional notification
        if ocr_text:
            await workflow.execute_activity(
                send_notification, user_id, ocr_text
            )

        return thumbnail_key
```

This code looks like a regular synchronous function, but it is durable. Temporal records every event. If the worker crashes in the middle of `run_ocr`, the workflow is automatically reconstructed and replayed from the last checkpoint. You can run this locally, you can unit test it, and you can debug it with a debugger. This is the _orchestrator_ we were missing.

**Option 2: Smarter Infrastructure (Kubernetes + Dapr)**

If you prefer to stay closer to the infrastructure, using Kubernetes with a sidecar like **Dapr** (Distributed Application Runtime) provides a similar abstraction. Dapr provides state management, pub/sub, and service invocation as sidecar APIs. Your Lambda-like functions can be deployed as microservices, and Dapr handles the state, retries, and actor model for you. This gives you the isolation of a function with the orchestration power of a stateful runtime.

**Option 3: Accept the Complexity and Build Better Tooling**

If you are locked into a pure AWS serverless stack, you must accept the complexity. Invest heavily in:

- **Infrastructure as Code testing**: Use tools like `aws-stepfunctions-sdk` to programmatically build state machines and test them locally.
- **End-to-end tracing**: Ensure your tracing setup is flawless. Use custom middleware in every Lambda to propagate trace IDs.
- **Automated resilience testing**: Proactively kill functions, introduce latency, and corrupt payloads in your staging environment. Verify that your sagas work correctly.

### Conclusion: The Promise, Re-Contextualized

Serverless computing gave us a gift: the ability to write stateless, scalable code without managing servers. But it was a Faustian bargain. The simplicity of the function was offset by the complexity of the orchestration. We traded server management for workflow management, and we were given a JSON file as a conductor’s baton.

The promise of serverless is not broken; it is misinterpreted. The compute _is_ ephemeral, but the _workflow must be durable_. Accepting this duality is the first step toward building robust serverless systems. Stop trying to conduct your symphony by shouting instructions through a state machine console. Start using tools that treat orchestration as a first-class citizen of your codebase.

Your "simple" workflow is a distributed system. Treat it like one. Give your amnesiac functions a durable memory. Build orchestrators, not just choreographers. And for the love of all that is holy, stop debugging production issues by staring at a JSON execution history. Your future self—and your on-call team—will thank you.

---

**End of Expanded Blog Post.**
