---
layout: post
topic: javascript
title: Synchronizing asynchronous tasks in Javascript
---
The title of this post is not what I would have hoped to come up with, but bear with me, I'm getting used to writing.

I recently had to write a component in the project I'm working on at the moment which requires a long list of asynchronous tasks to be orchestrated in some form to avoid race-condition bugs, so I thought I would write about how we solved this. We leverage most of the latest Ecmascript features in this project, so the code samples in this post will use some of those features.

**DISCLAIMER:** Do not use the code samples included in this post in your application, they are simplified and not meant to be used in real applications.

Before digging deeper, why do we want to synchronize async code? Or what do I mean by this? Picture the following fictional code:

```javascript
async function updateVisitorsCounter(externalDataStore) {
  const counter = await externalDataStore.getCounter();
  const newCounterValue = counter + 1;
  const result = await externalDataStore.updateCounterValue(newCounterValue);
  return result;
}
```

The function described above updates the value of a counter stored in an external data store (this could be, for example, a database). The code should work as expected:

  - Read the current value of the counter.
  - Add one to the read value.
  - Save the new updated value in the external data store.

However, this code is problematic. If this function is consumed by, say, an HTTP request handler, we could be looking at something like this:

```javascript
async function handleVisit(req, res) {
  const visitorNumber = await updateVisitorsCounter(externalDataStore);
  res.send(`You are visitor number ${visitorNumber}!`);
}
```

A race condition could be triggered if two or more HTTP requests are handled within a very short time between each other. Suppose we start with a counter value of 0 and 2 HTTP requests are handled at __almost__ the same time. The execution order of our `updateVisitorsCounter` function could lead to both users being returned a response that tells them both of them are visitor number 1, and our counter state wouldn't keep track of the number of visits properly. This is how it could go:

```javascript
  // visitor 1 triggers a call to updateVisitorsCounter
  // counter value: 0
  const counter = await externalDataStore.getCounter();
  // getCounter is called, but has not resolved yet.

  // visitor 2 triggers a call to updateVisitorsCounter
  // counter value: 0
  const counter = await externalDataStore.getCounter();

  // Back to visitor 1
  const counter = await externalDataStore.getCounter();
  // getCounter resolves, `counter` is assigned the value 0
  const newCounterValue = counter + 1;
  // newCounterValue = 1
  const result = await externalDataStore.updateCounterValue(newCounterValue);
  // updateCounterValue is called with the updated value set to 1
  // updateCounterValue has not resolved yet.

  // Back to visitor 2
  const counter = await externalDataStore.getCounter();
  // getCounter resolves before visitor 1's sequence updates the value of the
  // counter, `counter` is assigned the value 0
  // Uh-oh, this is wrong.
```

We could keep going, but the point here is, the sequence in which the code was executed triggered a race condition that messed with how we track visitors. Besides, `updateVisitorsCounter` is a very simple example of async code that could trigger these kind of race conditions, more complex sequences could lead to bugs that are very hard to debug. How can we prevent this?

Javascript is designed to run in a single threaded runtime environment, so concepts like locks are not common when writing JS code, could we use a construct that resembles a lock for this use case? Probably, but since we don't have multiple threads, a locking mechanism is not as straight-forward as it would be in a programming language with multi-threading support.

Let's look at an example that uses a crude concept of a lock:

```javascript
// we will use a function that simulates an idle waiting time
const wait = (time) => new Promise((resolve) => setTimeout(resolve, time));


function getCounterUpdater() {
  let lock = false;

  return async function(externalDataStore) {
    // If the lock is taken, wait 100ms before trying to acquire it again.
    while (lock) { await wait(100); }
    lock = true;
    const counter = await externalDataStore.getCounter();
    const newCounterValue = counter + 1;
    const result = await externalDataStore.updateCounterValue(newCounterValue);
    lock = false;
    return result;
  }
}

const updateVisitorsCounter = getCounterUpdater();
```

Now our HTTP handlers can call `updateVisitorsCounter` without worrying about race conditions. This doesn't come without drawbacks though:

  - Locking related logic is mixed within our application's logic.
  - Potentially, there is a lot of idle time while each call to `updateVisitorsCounter` waits for their turn, fine-tuning the amount of time to wait between retries can be a daunting task.
  - What happens if one of our calls to the external data store never resolves? How do we handle a rogue task never releasing the lock?

With all these drawbacks in mind, the question is, can we do better? 

## sync-queues

The solution we thought of in my team started out with something similar to what we have seen so far in this post, and after a few iterations I decided to isolate it in a separate package which you can find in the npm registry: https://www.npmjs.com/package/sync-queues

The solution abstracts all the mechanisms required to synchronize calls to complex asynchronous flows. Without diving into the code (which is accessible in the package [github repository](https://github.com/sergelerator/sync-queues)), sync-queues allows us to define queues of tasks that are guaranteed to run from start to finish without other tasks in the queue interfering.

Using this package, we can refactor the code sample above to the following:

```javascript
import syncQueue from "sync-queues";

const counterQueue = syncQueue();

async function updateVisitorsCounter(externalDataStore) {
  const counter = await externalDataStore.getCounter();
  const newCounterValue = counter + 1;
  const result = await externalDataStore.updateCounterValue(newCounterValue);
  return result;
}

async function handleVisit(req, res) {
  const visitorNumber = await counterQueue.run(
    async () => updateVisitorsCounter(externalDataStore)
  );
  res.send(`You are visitor number ${visitorNumber}!`);
}
```

## How does this work?

Calling `syncQueue` returns an object with a `run` method. Under the hood, a syncQueue uses a plain `Array` to store any tasks passed to `run` and a boolean flag to know whether a task is running or not, similar to the lock mechanism we saw earlier. However, tasks are dispatched as soon as possible instead of waiting an arbitrary amount of time before checking if the lock is up for grabs. So far, these features get rid of most of the drawbacks we had when using the locking technique we saw above. But how about rogue tasks that never finish? `syncQueue` accepts an optional parameter to set a timeout for any tasks assigned to it:

```javascript
async function test() {
  const q = syncQueue(100);
  try {
    await q.run(async () => await wait(1000)); // this task will time out
  } catch (err) {
    console.log('The task timed out!');
  }
}

test();
```

This way you can handle tasks timing out without affecting the rest of the queue. An example that illustrates this better:

```javascript
import syncQueue from "sync-queues";

const wait = (time) => new Promise((resolve) => setTimeout(resolve, time));

async function test() {
  const taskPromises = [];
  const results = [];
  const q = syncQueue(100);

  for (let i = 0; i < 200; i += 30) {
    taskPromises.push(q.run(async () => {
      await wait(200 - i);
      return i;
    }));
  }
  taskPromises.push(q.run(async () => {
    throw new Error('custom error');
  }));

  for (let i = 0; i < taskPromises.length; i++) {
    try {
      const result = await taskPromises[i];
      results.push(result);
    } catch (err) {
      console.log(err.toString());
    }
  }
  console.log(results);
}

test();

/* The console output for this test run:
Error: Task timed out
Error: Task timed out
Error: Task timed out
Error: Task timed out
Error: custom error
[ 120, 150, 180 ]
*/
```

As shown above, it is possible to handle any exception in the queue's tasks individually!

If you made it this far, thank you for reading!
