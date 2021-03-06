{-# LANGUAGE FlexibleContexts #-}

module Network.Trainer
( BackpropTrainer(..)
, CostFunction
, CostFunction'
, TrainingData
, Selection
, TrainCompletionPredicate

, trainNTimes
, trainUntilErrorLessThan
, trainUntil

, quadraticCost
, quadraticCost'
, minibatch
, online
, backprop
, inputs
, outputs
, deltas
, hiddenDeltas
, calculateNablas
, fit
, evaluate
) where

import Network.Network
import Network.Neuron
import Network.Layer
import System.Random
import System.Random.Shuffle (shuffle')
import Data.List.Split (chunksOf)
import Numeric.LinearAlgebra

-- | Trainer is a typeclass for all trainer types - a trainer will take in
--   an instance of itself, a network, a list of training data, and return a
--   new network trained on the data.
--class Trainer a where
--  fit :: (Floating b) => a -> Network b -> [TrainingData b] -> Network b

-- | A BackpropTrainer performs simple backpropagation on a neural network.
--   It can be used as the basis for more complex trainers.
data BackpropTrainer a = BackpropTrainer { eta :: a
                                         , cost :: CostFunction a
                                         , cost' :: CostFunction' a
                                         }

-- | A CostFunction is used for evaluating a network's performance on a given
--   input
type CostFunction a = Vector a -> Vector a -> a

-- | A CostFunction' (derivative) is used in backPropagation
type CostFunction' a = Vector a -> Vector a -> Vector a

-- | A tuple of (input, expected output)
type TrainingData a = (Vector a, Vector a)

-- | A selection function for performing gradient descent
type Selection a = [TrainingData a] -> [[TrainingData a]]

-- | A predicate (given a network, trainer, a list of training
--   data, and the number of [fit]s performed) that
--   tells the trainer to stop training
type TrainCompletionPredicate a = Network a -> BackpropTrainer a -> [TrainingData a] -> Int -> Bool

-- | Given a network, a trainer, a list of training data,
--   and N, this function trains the network with the list of
--   training data N times
trainNTimes :: (Floating (Vector a), Container Vector a, Product a)
  => Network a  -> BackpropTrainer a -> Selection a -> [TrainingData a] -> Int -> Network a
trainNTimes network trainer s dat n =
  trainUntil network trainer s dat completion 0
  where completion _ _ _ n' = (n == n')

-- | Given a network, a trainer, a list of training data,
--   and an error value, this function trains the network with the list of
--   training data until the error of the network (calculated
--   by averaging the errors of each training data) is less than
--   the given error value
trainUntilErrorLessThan :: (Floating (Vector a), Container Vector a, Product a, Ord a)
  => Network a  -> BackpropTrainer a -> Selection a -> [TrainingData a] -> a -> Network a
trainUntilErrorLessThan network trainer s dat err =
  trainUntil network trainer s dat (networkErrorLessThan err) 0

-- | This function returns true if the error of the network is less than
--   a given error value, given a network, a trainer, a list of
--   training data, and a counter (should start with 0)
--   Note: Is there a way to have a counter with a recursive function
--         without providing 0?
networkErrorLessThan :: (Floating (Vector a), Container Vector a, Product a, Ord a)
  => a -> Network a -> BackpropTrainer a -> [TrainingData a] -> Int -> Bool
networkErrorLessThan err network trainer dat _ = meanError < err
  where meanError = (sum errors) / fromIntegral (length errors)
        errors = map (evaluate trainer network) dat

-- | This function trains a network until a given TrainCompletionPredicate
--   is satisfied.
trainUntil :: (Floating (Vector a), Container Vector a, Product a)
  => Network a -> BackpropTrainer a -> Selection a -> [TrainingData a] -> TrainCompletionPredicate a -> Int -> Network a
trainUntil network trainer s dat completion n =
  if completion network trainer dat n
    then network
    else trainUntil network' trainer s dat completion (n+1)
      where network' = fit s trainer network dat

-- | The quadratic cost function (1/2) * sum (y - a) ^ 2
quadraticCost :: (Floating (Vector a), Container Vector a)
  => Vector a -> Vector a -> a
quadraticCost y a = sumElements $ 0.5 * (a - y) ** 2

-- | The derivative of the quadratic cost function sum (y - a)
quadraticCost' :: (Floating (Vector a))
  => Vector a -> Vector a -> Vector a
quadraticCost' y a = a - y

-- | The minibatch function becomes a Selection when partially applied
--   with the minibatch size
minibatch :: (Floating (Vector a), Container Vector a)
  => Int -> [TrainingData a] -> [[TrainingData a]]
minibatch size = chunksOf size

-- | If we want to train the network online
online :: (Floating (Vector a), Container Vector a)
  => [TrainingData a] -> [[TrainingData a]]
online = minibatch 1

-- | Declare the BackpropTrainer to be an instance of Trainer.
--instance (Floating a) => Trainer (BackpropTrainer a) where
fit :: (Floating (Vector a), Container Vector a, Product a)
  => Selection a -> BackpropTrainer a -> Network a -> [TrainingData a] -> Network a
fit s t n examples = foldl (backprop t) n $
  s (shuffle' examples (length examples) (mkStdGen 4))

-- | Perform backpropagation on a single training data instance.
backprop :: (Floating (Vector a), Container Vector a, Product a)
  => BackpropTrainer a -> Network a -> [TrainingData a] -> Network a
backprop t n es =
  updateNetwork (length es) t (foldl (calculateNablas t n) emptyNetwork es) n

-- | Given the size of the minibatch, the trainer, the nablas for each layer, given
--   as a network, and the network itself, return a network with updated wieghts.
updateNetwork :: (Floating (Vector a), Container Vector a, Product a)
  => Int -> BackpropTrainer a -> Network a -> Network a -> Network a
updateNetwork mag t nablas n = addNetworks n
  (Network $ map (scaleLayer $ -1 * (eta t) / (fromIntegral mag)) (layers nablas))

-- | Calculate the nablas for a minibatch and return them as a network (so each
--   weight and bias gets its own nabla).
calculateNablas :: (Floating (Vector a), Container Vector a, Product a)
  => BackpropTrainer a -> Network a -> Network a -> TrainingData a -> Network a
calculateNablas t n nablas e = Network $ map (updateLayer t) (zip3 (layers n) ds os)
  where ds = deltas t n e
        os = outputs (fst e) n

-- | The mapped function to update the weight and biases in a single layer
updateLayer :: (Floating (Vector a), Container Vector a, Product a)
  => BackpropTrainer a -> (Layer a, Vector a, Vector a) -> Layer a
updateLayer t (l, delta, output) = Layer newWeight newBias n
  where n = neuron l
        newWeight = ((reshape 1 delta) <> (reshape (dim output) output))
        newBias = delta

-- | The outputs function scans over each layer of the network and stores the
--   activated results
outputs :: (Floating (Vector a), Container Vector a, Product a)
  => Vector a -> Network a -> [Vector a]
outputs input network = scanl apply input (layers network)

-- | The inputs function performs a similar task to outputs, but returns a list
--   of vectors of unactivated inputs
inputs :: (Floating (Vector a), Container Vector a, Product a)
  => Vector a -> Network a -> [Vector a]
inputs input network = if null (layers network) then []
  else unactivated : inputs activated (Network (tail $ layers network))
    where unactivated = weightMatrix layer <> input + biasVector layer
          layer = head $ layers network
          activated = mapVector (activation (neuron layer)) unactivated

-- | The deltas function returns a list of layer deltas.
deltas :: (Floating (Vector a), Container Vector a, Product a)
  => BackpropTrainer a -> Network a -> TrainingData a -> [Vector a]
deltas t n example = hiddenDeltas
  (Network (reverse (layers n))) outputDelta (tail $ reverse is)
    ++ [outputDelta]
  where outputDelta = costd (snd example) output *
          mapVector activationd lastInput
        costd = cost' t
        activationd = activation' (neuron (last (layers n)))
        output = last os
        lastInput = last is
        is = inputs (fst example) n
        os = outputs (fst example) n

-- | Compute the hidden layer deltas
hiddenDeltas :: (Floating (Vector a), Container Vector a, Product a)
  => Network a -> Vector a -> [Vector a] -> [Vector a]
hiddenDeltas n prevDelta is = if length (layers n) <= 1 then []
  else delta : hiddenDeltas rest delta (tail is)
  where rest = Network (tail $ layers n)
        delta = (trans w) <> prevDelta * spv
        w = weightMatrix (head $ layers n)
        spv = mapVector (activation' (neuron (head $ layers n))) (head is)

-- | Use the cost function to determine the error of a network
evaluate :: (Floating (Vector a), Container Vector a, Product a)
  => BackpropTrainer a -> Network a -> TrainingData a -> a
evaluate t n example = (cost t) (snd example) (predict (fst example) n)
