import mongoose from 'mongoose';
import config from './config/index.js';

mongoose.set('strictQuery', true);

export const connectDb = async () => {
  await mongoose.connect(config.mongoUri, {
    serverSelectionTimeoutMS: 10_000,
  });
  return mongoose.connection;
};

export default connectDb;
